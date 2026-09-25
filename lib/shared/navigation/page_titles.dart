import 'package:flutter/material.dart';
import '../../core/config/restaurant_mode.dart';
import '../../core/i18n/app_localizations.dart';

/// Mappe une route GoRouter (`/shop/<id>/...`) vers le **titre exact** à
/// afficher dans l'AppBar du shell global. Le titre reflète la page
/// courante, y compris sous-pages et sous-sous-pages.
///
/// Retourne `null` si aucun titre explicite n'est défini pour la route :
/// le shell appliquera alors son fallback (label de l'item nav, ou
/// dérivation depuis le dernier segment d'URL).
///
/// **Comment étendre** : ajouter le case correspondant dans le `switch`
/// ci-dessous, en utilisant la clé i18n quand elle existe (`l.xxx`)
/// plutôt qu'une string en dur.
String? titleForLocation({
  required String location,
  required String shopId,
  required AppLocalizations l,
  String? tabQuery,
}) {
  // Strip le préfixe `/shop/<shopId>` pour faire un switch lisible.
  final prefix = '/shop/$shopId';
  var path = location.startsWith(prefix)
      ? location.substring(prefix.length)
      : location;
  // Strip query string pour le matching ; le tab est passé séparément.
  final qmark = path.indexOf('?');
  if (qmark >= 0) path = path.substring(0, qmark);
  if (path.isEmpty) path = '/';

  // ── Cas particulier : /parametres/shop avec tab variable ────────────
  if (path == '/parametres/shop') {
    switch (tabQuery) {
      case 'members':  return l.navMembers;
      case 'general':  return 'Paramètres boutique';
      case 'caisse':   return 'Configuration caisse';
      case 'danger':   return l.paramDangerZone;
      default:         return 'Paramètres boutique';
    }
  }

  // ── Cas dynamiques (préfixe d'URL) ───────────────────────────────────
  if (path.startsWith('/crm/client/'))            return 'Détail client';
  if (path.startsWith('/inventaire/product/'))    return 'Modifier le produit';
  if (path.startsWith('/parametres/locations/'))  return 'Emplacement';
  if (path.startsWith('/restaurant/addition/'))   return 'Addition';

  // ── Routes statiques exactes ─────────────────────────────────────────
  switch (path) {
    // Racine shop
    case '/':                              return l.navDashboard;
    case '/dashboard':                     return l.navDashboard;
    case '/caisse':                        return l.navCaisse;
    // « Carte » en restauration — cohérent avec le libellé de navigation.
    case '/inventaire':
      return isCurrentShopRestaurant() ? 'Menu' : l.navInventaire;
    case '/crm':                           return l.navClients;
    case '/finances':                      return l.navFinances;
    case '/historique':                    return l.navHistorique;
    case '/depenses':                      return 'Dépenses';
    case '/hub':                           return l.navHub;

    // Inventaire — sous-pages
    case '/inventaire/product':            return 'Nouveau produit';
    case '/inventaire/incidents':          return 'Incidents';
    case '/inventaire/movements':          return 'Mouvements de stock';
    case '/inventaire/arrivals':           return 'Arrivages';
    case '/inventaire/locations':          return 'Emplacements de stock';
    case '/inventaire/suppliers':          return 'Fournisseurs';

    // Restaurant — sous-pages. Sans elles, le repli dérivait le titre de
    // l'URL : « Cloture », « Reconcile », « Setup » — de l'anglais et des
    // accents manquants, affichés à l'utilisateur (lot Shell, 25/09/2026).
    // Chaque titre reprend celui que la page se donne elle-même.
    case '/restaurant/caisse/cloture':     return 'Clôture de caisse';
    case '/restaurant/inventory/reconcile': return 'Inventaire';
    case '/restaurant/setup':              return 'Configuration';
    case '/restaurant/pointage':           return 'Badgeuse';

    // Paramètres — racine + sous-pages
    case '/parametres':                    return l.navSettings;
    case '/parametres/profile':            return l.paramProfile;
    case '/parametres/payments':           return l.paramPayments;
    case '/parametres/delivery-templates': return l.deliveryTemplatesTitle;
    case '/parametres/language':           return l.paramLanguage;
    case '/parametres/theme':              return l.paramTheme;
    case '/parametres/currency':           return l.paramCurrency;
    case '/parametres/notifications':      return l.paramNotifications;
    case '/parametres/sessions':           return 'Sessions actives';
    case '/parametres/security-history':   return 'Historique sécurité';
    case '/parametres/locations':          return 'Emplacements de stock';
    case '/parametres/transfers':          return 'Transferts';
    case '/parametres/activity':           return 'Journal d\'activité';
    case '/parametres/users':              return l.navMembers;
    case '/parametres/pin/delete':         return 'Supprimer le PIN';
    case '/parametres/danger':             return l.paramDangerZone;
  }
  return null;
}

/// Helper pour récupérer le `tabQuery` depuis la location courante.
/// Utilisé conjointement à [titleForLocation].
String? extractTabQuery(BuildContext _, String location) {
  final qmark = location.indexOf('?');
  if (qmark < 0) return null;
  final query = Uri.splitQueryString(location.substring(qmark + 1));
  return query['tab'];
}
