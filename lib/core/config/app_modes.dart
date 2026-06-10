/// Drapeau temporaire « e-commerce uniquement ».
///
/// Quand `true` :
///   • la création de boutique force le secteur `'ecommerce'` (le sélecteur de
///     secteur est masqué dans les 3 tunnels : create_shop, inscription,
///     onboarding) ;
///   • la caisse se comporte TOUJOURS en e-commerce (panier « Enregistrer la
///     commande », jamais « Encaisser »).
///
/// Les autres modes (restaurant, retail, supermarché, pharmacie…) seront
/// réactivés plus tard en repassant ce drapeau à `false` — AUCUN code n'a été
/// supprimé, seuls les défauts/branches d'affichage changent.
///
/// NB : déclaré `final` (et non `const`) À DESSEIN → les branches
/// `if (!kEcommerceOnlyMode) …` qui conservent les sélecteurs ne déclenchent
/// pas d'avertissement `dead_code` tant que le drapeau vaut `true`.
final bool kEcommerceOnlyMode = true;
