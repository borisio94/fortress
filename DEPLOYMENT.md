# Déploiement des liens universels Fortress sur Netlify

Ce guide explique comment publier le dossier `web/` sur Netlify pour activer
les **Android App Links** et **iOS Universal Links** qui ouvrent Fortress
directement sur les liens `https://stately-sunshine-3593ef.netlify.app/accept-invite?token=…`.

---

## 1. Déploiement Netlify en 3 clics

1. **Créer un compte gratuit** sur <https://app.netlify.com/signup> (email ou GitHub).
2. **Drag & drop** : sur le tableau de bord, faire glisser le dossier `web/`
   entier (pas son contenu — le dossier lui-même) dans la zone
   *"Want to deploy a new site without connecting to Git? Drag and drop
   your site output folder here"*.
3. **Récupérer l'URL** générée (ex. `https://sparkly-cat-1234.netlify.app`)
   puis, dans *Site settings → Change site name*, la renommer en
   `fortress-app` → URL finale : `https://stately-sunshine-3593ef.netlify.app`.

> Si le nom est déjà pris, choisir un autre slug et **remplacer toutes les
> occurrences de `stately-sunshine-3593ef.netlify.app`** dans :
> - `web/.well-known/assetlinks.json` (pas nécessaire — le fichier n'y référence pas le domaine)
> - `android/app/src/main/AndroidManifest.xml` (attribut `android:host`)
> - `ios/Runner/Info.plist` (clé `com.apple.developer.associated-domains`)
> - `ios/Runner/Runner.entitlements`

---

## 2. Vérifier que les fichiers `.well-known` sont servis

Après déploiement, tester depuis un terminal :

```bash
curl -I https://stately-sunshine-3593ef.netlify.app/.well-known/assetlinks.json
curl -I https://stately-sunshine-3593ef.netlify.app/.well-known/apple-app-site-association
```

Les deux doivent renvoyer :
- `HTTP/2 200`
- `content-type: application/json`

Si `content-type` est `text/plain` ou `text/html`, vérifier que `web/netlify.toml`
est bien à la racine du dossier déployé.

Outils officiels de validation :
- Android : <https://developers.google.com/digital-asset-links/tools/generator>
- iOS : <https://branch.io/resources/aasa-validator/>

---

## 3. Remplir le SHA-256 du keystore Android

Après génération du keystore de production :

```bash
keytool -list -v -keystore <chemin-keystore>.jks -alias <alias> | grep SHA256
```

Copier la valeur (format `AA:BB:CC:…`) dans
`web/.well-known/assetlinks.json`, clé `sha256_cert_fingerprints` :

```json
"sha256_cert_fingerprints": [
  "AA:BB:CC:DD:EE:FF:..."
]
```

Redéployer ensuite via drag & drop (Netlify remplace l'ancien déploiement).

> **Play App Signing** : si l'app passe par Play App Signing (recommandé),
> récupérer **deux** empreintes dans la console Play Console →
> *Configuration → Intégrité de l'application* :
> - certificat de **signature d'application** (Google)
> - certificat de **signature de téléchargement** (développeur)
>
> Les deux doivent figurer dans le tableau `sha256_cert_fingerprints`.

---

## 4. iOS — compléter la configuration Xcode

Le fichier `ios/Runner/Runner.entitlements` a été créé, mais Xcode doit
l'activer explicitement :

1. Ouvrir `ios/Runner.xcworkspace` dans Xcode.
2. Sélectionner la cible **Runner** → onglet **Signing & Capabilities**.
3. Cliquer **+ Capability** → ajouter **Associated Domains**.
4. Vérifier la présence de `applinks:stately-sunshine-3593ef.netlify.app`.
5. Remplacer `TEAMID` par votre Apple Developer **Team ID** (10 caractères,
   ex. `A1B2C3D4E5`) dans `web/.well-known/apple-app-site-association` :

   ```json
   "appID": "A1B2C3D4E5.com.fortress.pos"
   ```

   Redéployer ensuite sur Netlify.

---

## 5. Android — ajuster le `applicationId`

Le `AndroidManifest.xml` et l'`assetlinks.json` utilisent le package
`com.fortress.pos`, mais `android/app/build.gradle.kts` contient encore
`com.example.fortress`. Avant publication :

```kotlin
// android/app/build.gradle.kts
namespace     = "com.fortress.pos"
applicationId = "com.fortress.pos"
```

Puis déplacer le code Kotlin sous `android/app/src/main/kotlin/com/fortress/pos/`.

---

## 6. Tests de bout en bout

**Android** (appareil physique, app installée en release) :
```bash
adb shell am start -a android.intent.action.VIEW \
  -d "https://stately-sunshine-3593ef.netlify.app/accept-invite?token=TEST"
```
Attendu : ouverture directe dans Fortress, **sans** popup de sélection.
Sinon, consulter :
```bash
adb shell pm get-app-links com.fortress.pos
```
Le statut doit être `verified` pour `stately-sunshine-3593ef.netlify.app`.

**iOS** (appareil physique, app installée) :
Envoyer le lien par iMessage ou Notes, puis taper dessus. Safari ne doit
**pas** s'ouvrir — l'app prend la main directement.

---

## 7. Route `/accept-invite` — déjà publique

Dans `lib/core/router/app_router.dart`, la route est explicitement autorisée
sans authentification :

```dart
if (isAcceptInviteRoute) return null;  // ← page publique, jamais rediriger
```

La page `AcceptInvitePage` gère elle-même les cas *invité / connecté /
mauvais compte*. Aucune modification supplémentaire n'est requise.

---

## 8. Note sur `web/index.html`

Le fichier original était le template Flutter Web. Il a été remplacé par une
**landing page statique** servie aux utilisateurs qui ouvrent le lien sans
avoir installé l'app. Conséquence : `flutter build web` n'est plus
fonctionnel sans restaurer le template d'origine. Ce projet vise mobile
uniquement, donc ce n'est pas bloquant — mais si un build web devient
nécessaire, isoler la landing page dans un dossier dédié (`netlify/`)
et restaurer le template Flutter dans `web/index.html`.
