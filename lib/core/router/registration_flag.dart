/// Drapeau global : true pendant le tunnel d'inscription (entre le clic
/// « Démarrer » et la redirection finale vers /auth/login).
///
/// Pendant cette fenêtre, l'auto-login post-signup rend la session active ;
/// sans ce drapeau, le `redirect` de GoRouter détournerait /auth/register
/// vers /subscription (plan pas encore actif + 0 boutique) AVANT que le
/// tunnel ait fini de créer la boutique puis de déconnecter → l'utilisateur
/// restait coincé sur le paywall « Expiré ». Le routeur consulte ce drapeau
/// pour NE PAS détourner les routes /auth/* tant que l'inscription est en
/// cours. Remis à false dès qu'on quitte le tunnel.
bool registrationInProgress = false;
