// Implémentation WEB du Pixel Facebook (Meta).
//
// Injecte le snippet officiel Meta dans le `<head>` (init + PageView) puis
// expose `trackFacebookEvent` qui appelle `fbq('track', ...)`. Tout est
// enveloppé de try/catch : le pixel ne doit JAMAIS casser le catalogue public
// (page critique côté chiffre d'affaires).
//
// Pattern d'interop : `package:web` + `dart:js_interop` (cf.
// `delivery_share_web.dart`), sélectionné via import conditionnel — aucun
// `dart:html`/`package:web` n'est tiré sur mobile (le stub `fb_pixel.dart` est
// choisi par défaut).

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Vrai une fois le snippet injecté avec succès. Empêche la double-injection
/// (rebuilds, navigations) et garde `trackFacebookEvent` muet tant que le
/// pixel n'est pas prêt.
bool _initialized = false;

/// Un ID de pixel Meta est purement numérique (15-16 chiffres en pratique).
/// Validation défensive : on n'injecte rien si l'ID ne ressemble pas à un
/// pixel, même si une valeur incohérente a été persistée.
final RegExp _pixelIdPattern = RegExp(r'^[0-9]{10,20}$');

void initFacebookPixel(String pixelId) {
  final id = pixelId.trim();
  if (_initialized || !_pixelIdPattern.hasMatch(id)) return;
  try {
    final head = web.document.head;
    if (head == null) return;
    _initialized = true;

    // Snippet officiel Meta : définit `fbq` (file d'attente synchrone), charge
    // fbevents.js en async, puis init + PageView. L'ID est interpolé.
    final script = web.HTMLScriptElement()
      ..text = '''
!function(f,b,e,v,n,t,s)
{if(f.fbq)return;n=f.fbq=function(){n.callMethod?
n.callMethod.apply(n,arguments):n.queue.push(arguments)};
if(!f._fbq)f._fbq=n;n.push=n;n.loaded=!0;n.version='2.0';
n.queue=[];t=b.createElement(e);t.async=!0;
t.src=v;s=b.getElementsByTagName(e)[0];
s.parentNode.insertBefore(t,s)}(window, document,'script',
'https://connect.facebook.net/en_US/fbevents.js');
fbq('init', '$id');
fbq('track', 'PageView');
''';
    head.appendChild(script);

    // Balise `<noscript>` standard Meta. Inerte dans une SPA Flutter (qui
    // exige JS pour démarrer) mais incluse pour rester fidèle à l'intégration
    // officielle.
    final noscript = web.document.createElement('noscript');
    final img = web.HTMLImageElement()
      ..height = 1
      ..width = 1
      ..src =
          'https://www.facebook.com/tr?id=$id&ev=PageView&noscript=1'
      ..style.display = 'none';
    noscript.appendChild(img);
    head.appendChild(noscript);
  } catch (_) {
    // Avale toute erreur DOM/JS : jamais au prix du catalogue.
  }
}

void trackFacebookEvent(String event, [Map<String, Object?>? params]) {
  if (!_initialized) return;
  try {
    // `fbq` peut être en file d'attente (script async pas encore chargé) :
    // l'appel est alors mis en queue puis rejoué — comportement attendu.
    if (globalContext.getProperty('fbq'.toJS) == null) return;
    if (params == null) {
      globalContext.callMethod('fbq'.toJS, 'track'.toJS, event.toJS);
    } else {
      globalContext.callMethod(
          'fbq'.toJS, 'track'.toJS, event.toJS, params.jsify());
    }
  } catch (_) {
    // Un évènement raté ne doit pas remonter à l'UI.
  }
}
