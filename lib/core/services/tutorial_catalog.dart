import 'package:flutter/material.dart';

import '../models/tutorial_step.dart';

/// Définition d'un tutoriel guidé : clé de persistance + métadonnées + étapes.
@immutable
class TutorialDef {
  final String key; // ex. 'tut_03' → flag SharedPreferences onboarding_tut_03
  final String title;
  final IconData icon;
  final String category; // pour le regroupement dans la page Aide
  final List<TutorialStep> steps;

  const TutorialDef({
    required this.key,
    required this.title,
    required this.icon,
    required this.category,
    required this.steps,
  });

  int get stepCount => steps.length;
}

/// Catalogue des tutoriels guidés (présentation modale, pas à pas).
///
/// Descriptions détaillées du PROCESSUS (où aller, quoi faire, ce qui se passe,
/// astuces). Textes alignés sur l'app réelle en mode e-commerce : on dit
/// « Enregistrer la commande » (jamais « Encaisser »), et il n'y a pas
/// d'ardoise client (TUT-12 volontairement absent).
const List<TutorialDef> kTutorialCatalog = [
  // ══ Commandes ════════════════════════════════════════════════════════════
  TutorialDef(
    key: 'tut_03',
    title: 'Passer une commande',
    icon: Icons.point_of_sale_rounded,
    category: 'Commandes',
    steps: [
      TutorialStep(
        icon: Icons.point_of_sale_rounded,
        title: 'Ouvrez la Caisse',
        description:
            'Dans le menu (à gauche sur ordinateur, en bas sur mobile), touchez « Caisse ». C\'est l\'écran où vous composez chaque commande de vos clients.',
      ),
      TutorialStep(
        icon: Icons.search_rounded,
        title: 'Cherchez un produit',
        description:
            'Tapez le nom ou le code (SKU) du produit dans la barre de recherche en haut. La liste se filtre en direct, à chaque lettre saisie.',
      ),
      TutorialStep(
        icon: Icons.add_shopping_cart_rounded,
        title: 'Ajoutez au panier',
        description:
            'Touchez la carte d\'un produit pour l\'ajouter au panier. Répétez pour chaque article ; ajustez les quantités directement dans le panier si besoin.',
      ),
      TutorialStep(
        icon: Icons.shopping_cart_rounded,
        title: 'Vérifiez le panier',
        description:
            'Ouvrez le panier (icône en haut à droite sur mobile, panneau de droite sur ordinateur) et contrôlez les articles, les quantités et le total avant de valider.',
      ),
      TutorialStep(
        icon: Icons.save_outlined,
        title: 'Enregistrez la commande',
        description:
            'Touchez « Enregistrer la commande ». Une fiche s\'ouvre pour le client, la date de livraison et le lieu. Validez : la commande apparaît dans « Commandes ».',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_04',
    title: 'Appliquer une remise',
    icon: Icons.local_offer_rounded,
    category: 'Commandes',
    steps: [
      TutorialStep(
        icon: Icons.local_offer_rounded,
        title: 'Réduire un article',
        description:
            'Dans le panier, touchez l\'icône remise sur la ligne de l\'article concerné — par exemple pour un produit légèrement abîmé ou un geste commercial.',
      ),
      TutorialStep(
        icon: Icons.percent_rounded,
        title: 'Pourcentage ou montant',
        description:
            'Choisissez le type de remise : un pourcentage (ex. -10 %) ou un montant fixe. Saisissez la valeur puis validez.',
      ),
      TutorialStep(
        icon: Icons.shopping_basket_rounded,
        title: 'Remise globale',
        description:
            'Pour réduire toute la commande plutôt qu\'un seul article, utilisez la remise globale, en bas du panier.',
      ),
      TutorialStep(
        icon: Icons.calculate_rounded,
        title: 'Total recalculé',
        description:
            'Le sous-total et le total à payer se mettent à jour automatiquement. La remise reste visible sur la facture du client.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_05',
    title: 'Commande avec acompte',
    icon: Icons.person_pin_circle_rounded,
    category: 'Commandes',
    steps: [
      TutorialStep(
        icon: Icons.person_add_alt_1_rounded,
        title: 'Associez un client',
        description:
            'En haut du panier, touchez « Sélectionner un client ». Lier un client permet de suivre ce qu\'il a payé et ce qu\'il reste à régler.',
      ),
      TutorialStep(
        icon: Icons.search_rounded,
        title: 'Cherchez ou créez',
        description:
            'Recherchez le client par nom ou téléphone. S\'il n\'existe pas encore, vous pouvez le créer directement depuis cette fenêtre.',
      ),
      TutorialStep(
        icon: Icons.payments_rounded,
        title: 'Saisissez l\'acompte',
        description:
            'Dans la fiche de commande, indiquez le montant déjà versé par le client (l\'acompte). Laissez 0 s\'il n\'a encore rien payé.',
      ),
      TutorialStep(
        icon: Icons.account_balance_wallet_rounded,
        title: 'Reste à payer suivi',
        description:
            'Si l\'acompte est inférieur au total, la commande passe en paiement « partiel » et le reste dû est calculé et suivi automatiquement.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_06',
    title: 'Annuler ou corriger une commande',
    icon: Icons.undo_rounded,
    category: 'Commandes',
    steps: [
      TutorialStep(
        icon: Icons.receipt_long_rounded,
        title: 'Commande non finalisée',
        description:
            'Ouvrez « Commandes » puis la commande à annuler. Une commande encore programmée, en cours ou refusée peut être supprimée.',
      ),
      TutorialStep(
        icon: Icons.delete_outline_rounded,
        title: 'Motif obligatoire',
        description:
            'Touchez Supprimer, saisissez un motif (10 caractères minimum) et confirmez. Le stock qui était réservé pour cette commande est automatiquement remis en stock.',
      ),
      TutorialStep(
        icon: Icons.lock_outline_rounded,
        title: 'Vente déjà encaissée',
        description:
            'Une vente déjà encaissée ne peut PAS être supprimée : c\'est une protection comptable. Dans ce cas, on corrige le stock à la place (étape suivante).',
      ),
      TutorialStep(
        icon: Icons.tune_rounded,
        title: 'Corriger le stock',
        description:
            'Allez dans Inventaire, ouvrez le produit, touchez « Corriger » et remettez la bonne quantité avec un motif (ex. « encaissé par erreur »).',
      ),
    ],
  ),

  // ══ Inventaire ═══════════════════════════════════════════════════════════
  TutorialDef(
    key: 'tut_07',
    title: 'Ajouter un produit',
    icon: Icons.inventory_2_rounded,
    category: 'Inventaire',
    steps: [
      TutorialStep(
        icon: Icons.inventory_2_rounded,
        title: 'Ouvrez l\'Inventaire',
        description:
            'Dans le menu, touchez « Inventaire ». Vous y voyez tous vos produits, avec leur stock et leurs prix.',
      ),
      TutorialStep(
        icon: Icons.add_rounded,
        title: 'Nouveau produit',
        description:
            'Touchez le bouton « + » (en haut à droite de la liste) pour ouvrir le formulaire de création.',
      ),
      TutorialStep(
        icon: Icons.edit_note_rounded,
        title: 'Champs essentiels',
        description:
            'Renseignez au minimum le nom, le prix de vente et le stock initial. Le reste est facultatif et pourra être complété plus tard.',
      ),
      TutorialStep(
        icon: Icons.photo_camera_rounded,
        title: 'Ajoutez une photo',
        description:
            'Une photo apparaît en caisse et surtout dans votre catalogue web : elle aide vos clients à reconnaître et choisir l\'article.',
      ),
      TutorialStep(
        icon: Icons.expand_more_rounded,
        title: 'Options avancées',
        description:
            'Dépliez les options avancées pour un SKU (code), des variantes (taille, couleur…) et une catégorie — pratique pour organiser un grand catalogue.',
      ),
      TutorialStep(
        icon: Icons.check_circle_outline_rounded,
        title: 'Enregistrez',
        description:
            'Validez : le produit devient immédiatement disponible en caisse ET dans votre catalogue web public.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_08',
    title: 'Ajuster le stock',
    icon: Icons.tune_rounded,
    category: 'Inventaire',
    steps: [
      TutorialStep(
        icon: Icons.edit_rounded,
        title: 'Ouvrez la correction',
        description:
            'Dans l\'Inventaire, ouvrez la fiche d\'un produit et touchez « Corriger », ou utilisez l\'icône crayon directement sur une variante dans la liste.',
      ),
      TutorialStep(
        icon: Icons.exposure_rounded,
        title: 'Quantité réelle',
        description:
            'Saisissez la quantité RÉELLE comptée en rayon. L\'application calcule automatiquement l\'écart (ajout ou retrait) par rapport à la quantité enregistrée.',
      ),
      TutorialStep(
        icon: Icons.description_rounded,
        title: 'Motif obligatoire',
        description:
            'Indiquez un motif (10 caractères min.) : casse, perte, inventaire physique, erreur… Chaque correction est tracée dans l\'historique, pour un stock fiable.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_09',
    title: 'Réceptionner une livraison',
    icon: Icons.local_shipping_rounded,
    category: 'Inventaire',
    steps: [
      TutorialStep(
        icon: Icons.move_to_inbox_rounded,
        title: 'Réceptions',
        description:
            'Allez dans Inventaire → Réceptions. C\'est ici qu\'on enregistre chaque livraison reçue d\'un fournisseur, pour augmenter le stock proprement.',
      ),
      TutorialStep(
        icon: Icons.add_rounded,
        title: 'Nouvelle réception',
        description:
            'Touchez « + » pour créer une réception. Vous pouvez partir d\'une commande fournisseur existante ou saisir une réception directe.',
      ),
      TutorialStep(
        icon: Icons.store_rounded,
        title: 'Fournisseur',
        description:
            'Sélectionnez le fournisseur qui a livré — cela permet de suivre vos achats par fournisseur.',
      ),
      TutorialStep(
        icon: Icons.add_box_rounded,
        title: 'Produits reçus',
        description:
            'Ajoutez chaque produit reçu et la quantité livrée. Vérifiez que les quantités correspondent bien au bon de livraison.',
      ),
      TutorialStep(
        icon: Icons.check_circle_outline_rounded,
        title: 'Validez',
        description:
            'À la validation, le stock de chaque produit augmente automatiquement des quantités reçues. La réception reste consultable dans l\'historique.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_10',
    title: 'Transférer vers un partenaire',
    icon: Icons.swap_horiz_rounded,
    category: 'Inventaire',
    steps: [
      TutorialStep(
        icon: Icons.swap_horiz_rounded,
        title: 'Transferts',
        description:
            'Allez dans Paramètres → Transferts (ou via les Emplacements de stock). Un transfert confie une partie de votre stock à un partenaire de livraison.',
      ),
      TutorialStep(
        icon: Icons.place_rounded,
        title: 'Destination partenaire',
        description:
            'Choisissez le partenaire (emplacement de type « partenaire ») qui va recevoir et garder ce stock pour ses livraisons.',
      ),
      TutorialStep(
        icon: Icons.numbers_rounded,
        title: 'Quantité',
        description:
            'Indiquez, pour chaque produit, le nombre d\'unités à transférer. Ce stock est déduit de votre boutique et ajouté chez le partenaire.',
      ),
      TutorialStep(
        icon: Icons.menu_book_rounded,
        title: 'Confirmation',
        description:
            'Validez : le mouvement est enregistré et le livre de compte du partenaire est mis à jour (vous savez ce qu\'il détient et ce qu\'il vous doit).',
      ),
    ],
  ),

  // ══ Clients ══════════════════════════════════════════════════════════════
  TutorialDef(
    key: 'tut_11',
    title: 'Ajouter un client',
    icon: Icons.group_add_rounded,
    category: 'Clients',
    steps: [
      TutorialStep(
        icon: Icons.people_alt_rounded,
        title: 'Clients',
        description:
            'Dans le menu, ouvrez « Clients ». Vous y gérez votre fichier clients : coordonnées, historique d\'achats et fidélité.',
      ),
      TutorialStep(
        icon: Icons.add_rounded,
        title: 'Nouveau client',
        description: 'Touchez « + » pour créer une nouvelle fiche client.',
      ),
      TutorialStep(
        icon: Icons.contact_phone_rounded,
        title: 'Nom + téléphone',
        description:
            'Renseignez au minimum le nom et le téléphone. L\'e-mail, la ville et l\'adresse sont facultatifs mais utiles pour les livraisons et les relances WhatsApp.',
      ),
      TutorialStep(
        icon: Icons.check_circle_outline_rounded,
        title: 'Enregistrez',
        description:
            'Validez : ce client pourra être associé à vos commandes, ce qui alimente automatiquement son historique et son total dépensé.',
      ),
    ],
  ),

  // ══ Équipe & Partenaires ═════════════════════════════════════════════════
  TutorialDef(
    key: 'tut_13',
    title: 'Inviter un employé',
    icon: Icons.person_add_rounded,
    category: 'Équipe & Partenaires',
    steps: [
      TutorialStep(
        icon: Icons.badge_rounded,
        title: 'Employés & permissions',
        description:
            'Allez dans Paramètres → Boutique → « Employés & permissions ». C\'est là que vous gérez qui a accès à votre boutique, et avec quels droits.',
      ),
      TutorialStep(
        icon: Icons.mail_rounded,
        title: 'Inviter',
        description:
            'Touchez « Inviter » et saisissez l\'e-mail de la personne. Elle recevra un lien pour rejoindre votre boutique.',
      ),
      TutorialStep(
        icon: Icons.admin_panel_settings_rounded,
        title: 'E-mail + rôle',
        description:
            'Choisissez le rôle « admin » (gestion large) ou « user » (vendeur, actions limitées), puis affinez les permissions : gérer le stock, appliquer des remises, voir les rapports…',
      ),
      TutorialStep(
        icon: Icons.send_rounded,
        title: 'Envoi',
        description:
            'Envoyez l\'invitation. Dès que la personne l\'accepte, elle accède à la boutique avec exactement les droits que vous avez définis.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_14',
    title: 'Créer un partenaire de livraison',
    icon: Icons.local_shipping_rounded,
    category: 'Équipe & Partenaires',
    steps: [
      TutorialStep(
        icon: Icons.place_rounded,
        title: 'Partenaires',
        description:
            'Allez dans Paramètres → Partenaires (ou Emplacements de stock). Un partenaire est un livreur ou un dépôt à qui vous confiez du stock.',
      ),
      TutorialStep(
        icon: Icons.add_rounded,
        title: 'Nouveau partenaire',
        description: 'Touchez « + » et choisissez le type « Partenaire ».',
      ),
      TutorialStep(
        icon: Icons.contact_phone_rounded,
        title: 'Nom + contact',
        description:
            'Renseignez le nom et le numéro de téléphone du partenaire. Le téléphone sert notamment aux messages WhatsApp de livraison.',
      ),
      TutorialStep(
        icon: Icons.check_circle_outline_rounded,
        title: 'Confirmation',
        description:
            'Validez : vous pourrez désormais lui transférer du stock (voir « Transférer vers un partenaire ») et suivre son solde.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_15',
    title: 'Régler un partenaire',
    icon: Icons.account_balance_wallet_rounded,
    category: 'Équipe & Partenaires',
    steps: [
      TutorialStep(
        icon: Icons.receipt_long_rounded,
        title: 'Fiche partenaire',
        description:
            'Allez dans Paramètres → Partenaires et ouvrez la fiche du partenaire. Le solde indique clairement qui doit de l\'argent à qui.',
      ),
      TutorialStep(
        icon: Icons.menu_book_rounded,
        title: 'Livre de compte',
        description:
            'Le livre de compte liste toutes les transactions (stock confié, ventes, versements) et le solde cumulé, ligne après ligne.',
      ),
      TutorialStep(
        icon: Icons.payments_rounded,
        title: 'Enregistrer un paiement',
        description:
            'À chaque versement reçu du partenaire (ou payé au partenaire), enregistrez-le ici. Le solde se met à jour pour rester juste.',
      ),
    ],
  ),

  // ══ Personnalisation ═════════════════════════════════════════════════════
  TutorialDef(
    key: 'tut_16',
    title: 'Ajouter le logo de la boutique',
    icon: Icons.image_rounded,
    category: 'Personnalisation',
    steps: [
      TutorialStep(
        icon: Icons.storefront_rounded,
        title: 'Boutique → Logo',
        description:
            'Allez dans Paramètres → Boutique, section Logo. Votre logo apparaît sur vos factures et sur votre catalogue web.',
      ),
      TutorialStep(
        icon: Icons.photo_library_rounded,
        title: 'Choisir une image',
        description:
            'Sélectionnez une image depuis votre appareil. Préférez une image carrée et nette pour un meilleur rendu.',
      ),
      TutorialStep(
        icon: Icons.palette_rounded,
        title: 'Thème depuis le logo',
        description:
            'Fortress peut générer automatiquement une palette de couleurs assortie à votre logo, pour une app aux couleurs de votre marque.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_17',
    title: 'Changer le thème',
    icon: Icons.color_lens_rounded,
    category: 'Personnalisation',
    steps: [
      TutorialStep(
        icon: Icons.tune_rounded,
        title: 'Préférences → Thème',
        description: 'Allez dans Paramètres → Préférences → « Thème ».',
      ),
      TutorialStep(
        icon: Icons.palette_rounded,
        title: 'Palettes',
        description:
            'Choisissez parmi 8 palettes de couleurs prédéfinies, ou la palette générée à partir de votre logo.',
      ),
      TutorialStep(
        icon: Icons.visibility_rounded,
        title: 'Aperçu immédiat',
        description:
            'Le changement s\'applique instantanément à toute l\'app. Essayez-en plusieurs avant de garder celle qui vous plaît.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_18',
    title: 'Générer et partager une facture',
    icon: Icons.picture_as_pdf_rounded,
    category: 'Personnalisation',
    steps: [
      TutorialStep(
        icon: Icons.receipt_long_rounded,
        title: 'Commande → Facture',
        description:
            'Ouvrez une commande, puis touchez « Facture ». La facture professionnelle est générée en un clic.',
      ),
      TutorialStep(
        icon: Icons.picture_as_pdf_rounded,
        title: 'Aperçu PDF',
        description:
            'Le PDF reprend automatiquement votre logo et vos couleurs, avec le détail des articles, le total et les infos du client.',
      ),
      TutorialStep(
        icon: Icons.share_rounded,
        title: 'Partager',
        description:
            'Partagez la facture par WhatsApp ou e-mail au client, ou imprimez-la — idéal pour confirmer une commande.',
      ),
    ],
  ),
  TutorialDef(
    key: 'tut_19',
    title: 'Activer le catalogue web',
    icon: Icons.public_rounded,
    category: 'Personnalisation',
    steps: [
      TutorialStep(
        icon: Icons.public_rounded,
        title: 'Catalogue web',
        description:
            'Allez dans Paramètres → Catalogue web (ou Inventaire → Partager le catalogue). Le catalogue est une vitrine en ligne de vos produits.',
      ),
      TutorialStep(
        icon: Icons.toggle_on_rounded,
        title: 'Activer',
        description:
            'Activez le catalogue public. Vos produits en stock deviennent alors visibles par vos clients.',
      ),
      TutorialStep(
        icon: Icons.link_rounded,
        title: 'Copier le lien',
        description:
            'Copiez le lien public (court) et partagez-le sur WhatsApp, vos statuts ou réseaux. Aucune application à installer pour le client.',
      ),
      TutorialStep(
        icon: Icons.shopping_bag_rounded,
        title: 'Aperçu',
        description:
            'Vos clients ouvrent le lien, parcourent vos produits (photos + prix) et passent commande en ligne — vous la recevez dans « Commandes ».',
      ),
    ],
  ),
];
