// Stub mobile / desktop natif — sur ces plateformes on retombe sur
// `url_launcher` (cf. `openExternal` ci-dessous). Cette fonction n'est
// utilisée que sur Flutter web (cf. conditional export dans
// `external_launcher.dart`).

bool openInNewTab(String url) => false;
