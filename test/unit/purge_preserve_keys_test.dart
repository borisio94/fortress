// Vérifie que la purge anti-fuite (clearAllForLogout) CONSERVE :
//   • les clés de préférences device listées en dur ;
//   • les clés dynamiques dont le préfixe est préservé (ex.
//     `onboarding_done_<uid>` → le tour de bienvenue ne réapparaît pas à
//     chaque reconnexion).
// et EFFACE tout le reste (données de compte : current_user_id, caches…).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fortress/core/storage/hive_boxes.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('fortress_purge_test');
    Hive.init(tmp.path);
    await Hive.openBox(HiveBoxes.settings);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('clearAllForLogout : préserve device + préfixe, efface le reste',
      () async {
    final box = HiveBoxes.settingsBox;
    await box.put('app_theme_mode', 'dark'); // pref device (exacte)
    await box.put('onboarding_done_user1', true); // préfixe préservé
    await box.put('current_user_id', 'user1'); // donnée compte → effacée
    await box.put('active_shop_user1', 'shopA'); // cache compte → effacé

    await HiveBoxes.clearAllForLogout(
      const {'app_theme_mode'},
      preserveSettingsKeyPrefixes: const {'onboarding_done_'},
    );

    expect(box.get('app_theme_mode'), 'dark');
    expect(box.get('onboarding_done_user1'), true);
    expect(box.get('current_user_id'), isNull);
    expect(box.get('active_shop_user1'), isNull);
  });

  test('sans préfixe préservé, onboarding_done_* est effacé', () async {
    final box = HiveBoxes.settingsBox;
    await box.put('onboarding_done_user2', true);

    await HiveBoxes.clearAllForLogout(const {});

    expect(box.get('onboarding_done_user2'), isNull);
  });
}
