// Implémentation web — ouverture d'URL externe **synchrone**, déclenchée
// depuis le tick du clic utilisateur. Indispensable pour bypass les
// popup blockers Chrome/Firefox/Safari qui rejettent les fenêtres
// ouvertes après n'importe quel `await` (même via `url_launcher` qui
// fait un round-trip via method channel).
//
// Stratégie en deux temps :
//   1. `window.open(url, '_blank')` — chemin direct.
//   2. Si bloqué (retour `null` côté JS), fallback via clic programmatique
//      sur une balise `<a target="_blank">` injectée dans le DOM. Ce
//      pattern est traité comme une navigation initiée par lien — la
//      plupart des bloqueurs de popups l'autorisent là où ils refusent
//      `window.open`.

// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

bool openInNewTab(String url) {
  // Tentative 1 : window.open direct.
  try {
    final w = html.window.open(url, '_blank');
    // `window.open` retourne null/undefined côté JS si le popup est
    // bloqué. Dart wrappe cette valeur, le `.toString()` vaut `'null'`.
    if (w.toString() != 'null') return true;
  } catch (_) {/* on tente le fallback ci-dessous */}

  // Tentative 2 : clic programmatique sur ancre — bypass plus fiable des
  // popup blockers car traité comme un user-initiated link click.
  try {
    final anchor = html.AnchorElement(href: url)
      ..target = '_blank'
      ..rel = 'noopener noreferrer';
    // Pas besoin d'attacher au DOM en pratique — `.click()` fonctionne
    // sur l'ancre détachée dans tous les navigateurs modernes. On
    // attache + détache quand même pour maximiser la compatibilité.
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    return true;
  } catch (_) {
    return false;
  }
}
