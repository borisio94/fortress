part of 'restaurant_menu_page.dart';

// La grille des plats et leurs cartes.

/// Grille des plats.
class _MenuGrid extends StatelessWidget {
  final List<Product> products;
  final String shopId;

  /// La grille montre-t-elle des plats RETIRÉS de la vente ?
  final bool retired;
  final bool isAdmin;
  final bool canDelete;
  final bool canEdit;
  final ValueChanged<Product> onTap;
  final ValueChanged<Product> onAdd;

  /// Le bouton flottant est-il affiché ? Décide de la marge basse
  /// ([kRestoFabClearance]) : sans elle, la dernière rangée passe sous lui.
  final bool fabShown;
  final void Function(Product, bool) onToggleDispo;
  final ValueChanged<Product> onEditCount;
  final ValueChanged<Product> onDelete;

  const _MenuGrid({
    required this.products,
    required this.shopId,
    required this.retired,
    required this.isAdmin,
    required this.canDelete,
    required this.canEdit,
    required this.onTap,
    required this.onAdd,
    this.fabShown = false,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, c) {
      const hPad = 16.0;
      // TOUTE LA GÉOMÉTRIE VIENT DE `menu_grid_geometry.dart`, sous test :
      // colonnes (plancher de 200 dp — 4 dès ~860 dp de contenu), hauteur de
      // photo (ratio 0,78 borné entre 104 et 150) et hauteur de tuile. La
      // tuile rend exactement les lignes que ce calcul compte.
      final layout = menuGridLayout(c.maxWidth - hPad * 2);
      final ts = MediaQuery.textScalerOf(context);
      final tileH = menuTileHeight(layout.photoHeight, ts.scale);

      return GridView.builder(
        // En bas : la place du bouton flottant quand il est là (80 = 48 + 16
        // + 16, cf. `kRestoFabClearance`), 24 sinon.
        padding: EdgeInsets.fromLTRB(
            hPad, 8, hPad, fabShown ? kRestoFabClearance : 24),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: layout.cols,
          mainAxisSpacing: kMenuRowGap,
          crossAxisSpacing: kMenuGap,
          // Hauteur FIXE issue du calcul, et non un ratio : c'est elle que le
          // test verrouille.
          mainAxisExtent: tileH,
        ),
        itemCount: products.length,
        itemBuilder: (_, i) => _DishCard(
          product: products[i],
          shopId: shopId,
          retired: retired,
          isAdmin: isAdmin,
          canDelete: canDelete,
          canEdit: canEdit,
          photoHeight: layout.photoHeight,
          onTap: () => onTap(products[i]),
          onAdd: () => onAdd(products[i]),
          onToggleDispo: (v) => onToggleDispo(products[i], v),
          onEditCount: () => onEditCount(products[i]),
          onDelete: () => onDelete(products[i]),
        ),
      );
    });
  }
}

/// Carte d'un plat — photo en plein cadre, informations dessous.
///
/// La photo était une vignette ronde de 70 px centrée. Ce cercle est le bon
/// objet au TABLEAU DE BORD, où il sert de bouton d'ajout rapide et où la
/// photo n'est qu'un repère. Ici l'écran est une surface de gestion : on y
/// regarde sa carte, et une carte se regarde d'abord en images.
///
/// La photo prend donc toute la largeur sur une hauteur dominante, et les
/// contrôles qui la surplombent reprennent le voile à 85 % du module — stock à
/// gauche, menu ⋮ à droite. Sous elle, deux lignes seulement : le nom, puis le
/// prix et le bouton d'ajout. La ligne « catégorie · stock » a disparu, la
/// catégorie étant déjà lisible dans le filtre actif au-dessus de la grille et
/// le stock étant passé sur la photo.
///
/// La carte porte DEUX zones tactiles, et non plus une seule :
///   • la PHOTO ajoute au panier ;
///   • le BLOC TEXTE ouvre la fiche du plat.
///
/// Plus de bouton d'ajout : la photo EST le bouton, sur toutes les largeurs.
/// Le geste n'est donc annoncé par aucun signe — seuls le retour au toucher et,
/// sur le web, l'infobulle au survol le révèlent. C'est assumé : un écran de
/// service se prend en main une fois, et le bouton coûtait une pastille sur
/// chaque photo de la grille.
///
/// CONSÉQUENCE À CONNAÎTRE : sous 720 dp, le volet panier recouvre l'écran
/// entier quand il s'ouvre. Un tap de travers pendant un défilement y bascule
/// donc sur le panier, qu'il faut refermer pour revenir à la carte. Le retour
/// arrière existe — chaque ligne du volet porte une corbeille — mais il n'y a
/// pas d'annulation en un geste : `AppSnack` n'expose pas de `SnackBarAction`.
///
/// Le bloc texte, et pas seulement le menu ⋮ : celui-ci n'apparaît qu'à qui
/// possède un droit d'édition ou de suppression, alors que la fiche en LECTURE
/// existe pour le serveur qui n'en a aucun — c'est lui qui doit répondre au
/// client demandant ce qu'il y a dans un plat. C'est aussi, pour un
/// administrateur, le seul chemin vers le formulaire depuis la carte, puisque
/// la photo ne l'ouvre plus.
class _DishCard extends StatelessWidget {
  final Product product;
  final String shopId;

  /// Plat RETIRÉ de la vente (`isActive == false`).
  ///
  /// Distinct de l'indisponibilité du jour, qui est locale au poste et remise à
  /// zéro chaque matin : ici le retrait est permanent et synchronisé.
  final bool retired;
  final bool isAdmin;
  final bool canDelete;
  final bool canEdit;

  /// Décidée par la GRILLE, qui seule connaît la largeur de carte, et reportée
  /// telle quelle dans la hauteur de tuile. Les deux doivent rester d'accord,
  /// sans quoi le bloc texte déborde.
  final double photoHeight;
  final VoidCallback onTap;
  final VoidCallback onAdd;
  final ValueChanged<bool> onToggleDispo;
  final VoidCallback onEditCount;
  final VoidCallback onDelete;

  const _DishCard({
    required this.product,
    required this.shopId,
    required this.retired,
    required this.isAdmin,
    required this.canDelete,
    required this.canEdit,
    required this.photoHeight,
    required this.onTap,
    required this.onAdd,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.onDelete,
  });

  /// Contenu de la zone photo : l'image, ou l'APLAT teinté qui la remplace.
  ///
  /// Le repli ne peut plus être le cercle du tableau de bord — il faut couvrir
  /// toute la zone. La teinte vient de [restoDishTint], partagée, pour qu'un
  /// plat sans photo garde la même couleur d'un écran à l'autre ; seule la
  /// forme change, et l'initiale se pose sur une pastille claire qui la détache
  /// de l'aplat.
  Widget _photo(BuildContext context) {
    final url = product.mainImageUrl;
    if (url != null && url.isNotEmpty) {
      // `ProductImageCard` cadre en `BoxFit.cover` : la photo remplit sans se
      // déformer, au prix d'une coupe sur les clichés très verticaux. Ce widget
      // est partagé avec l'e-commerce et n'expose ni `fit` ni `alignment` — on
      // ne l'ouvre pas pour cet écran. Un biais de cadrage serait de toute
      // façon un pari : sur une photo mal cadrée, il couperait le plat au lieu
      // de la nappe.
      return ProductImageCard(
        imageUrl: url,
        fillParent: true,
        borderRadius: BorderRadius.zero,
      );
    }
    final tint = restoDishTint(context, product);
    return ColoredBox(
      color: tint.withValues(alpha: 0.22),
      child: Center(
        child: Container(
          width: _kInitialDisc,
          height: _kInitialDisc,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.35),
          ),
          alignment: Alignment.center,
          child: Text(restoDishInitial(product),
              style: AppTextStyles.title.copyWith(color: tint)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sem = theme.semantic;
    // Dispo du jour (état local) : pilote le grisage de la photo, la ligne
    // d'état et la présence du bouton d'ajout. Lu à chaque build → suit les
    // setState déclenchés par les actions admin et le décrément à la commande.
    final avail = DailyMenuService.read(shopId, product.id ?? '');
    // Un plat retiré n'est jamais « disponible », quelle que soit la dispo du
    // jour : le réglage permanent l'emporte sur celui de la journée.
    final available = !retired && avail.isAvailable;

    final photo = _photo(context);
    // L'image n'ajoute que si elle a quelque chose à ajouter : sur un plat
    // indisponible elle ouvre la fiche. Les trois gardes de `_addToCart`
    // restent derrière de toute façon — elles couvrent les chemins qui ne
    // passent pas par cet écran.
    final tapAdds = available;

    // ── PLUS DE CARTE AUTOUR DE LA PHOTO ──────────────────────────────────
    //
    // Ni fond ni bordure : la photo EST le bloc, arrondie seule, et le texte
    // vit dessous, à nu sur le décor géométrique du module. C'est l'exception
    // écrite à la règle du 16/09 (cf. `restoGlassFill`) : le décor est
    // calculable — texte primaire ≥ 12,2:1, secondaire ≥ 5,2:1 sur le pire
    // cas des huit palettes — là où la règle visait une PHOTO de salle.
    // Rien de textuel ne se pose sur la photo sans son voile à 85 %.
    return Material(
      type: MaterialType.transparency,
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── PHOTO, LE BLOC ─────────────────────────────────────
            ClipRRect(
              borderRadius: BorderRadius.circular(_kPhotoRadius),
              child: SizedBox(
              height: photoHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Plat indisponible : la photo passe en GRIS. Elle est
                  // la plus grande surface de la carte, donc la seule
                  // chose qui se voie de l'autre bout de la salle — ce
                  // que faisait le tampon incliné en barrant le nom.
                  available
                      ? photo
                      : ColorFiltered(
                          colorFilter: _kGreyscale, child: photo),
                  // ZONE TACTILE DE LA PHOTO, posée PAR-DESSUS l'image.
                  //
                  // Un `InkWell` peint son encre sur le `Material` le
                  // plus proche, donc SOUS son enfant : enveloppé autour
                  // de la carte, son retour au toucher disparaissait
                  // derrière la photo. Un `Material` transparent placé
                  // ici, au-dessus de l'image, rend l'encre visible sur
                  // la photo — et c'est justement ce qui annonce qu'il
                  // s'y passe quelque chose.
                  Positioned.fill(
                    child: Material(
                      type: MaterialType.transparency,
                      child: Tooltip(
                        message: tapAdds
                            ? 'Ajouter au panier'
                            : 'Voir la fiche du plat',
                        child: InkWell(
                          onTap: tapAdds ? onAdd : onTap,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: _StockBadge(
                      value: avail.count == null ? '∞' : '${avail.count}',
                      soldOut: !available,
                    ),
                  ),
                  // Sur un plat RETIRÉ, la dispo du jour et son stock ne
                  // veulent plus rien dire — mais rouvrir sa fiche ou le
                  // supprimer, si : c'est même tout l'objet de la liste
                  // des plats retirés.
                  if (retired
                      ? (canEdit || canDelete)
                      : (isAdmin || canEdit || canDelete))
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SizedBox(
                        width: _kBadgeTap,
                        height: _kBadgeTap,
                        child: _DishMenuBtn(
                          onEdit: canEdit ? onTap : null,
                          onDelete: canDelete ? onDelete : null,
                          onToggleDispo: isAdmin && !retired
                              ? () => onToggleDispo(!avail.enabled)
                              : null,
                          onEditCount:
                              isAdmin && !retired ? onEditCount : null,
                          dispoEnabled: avail.enabled,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ),

            // ── BLOC TEXTE ─────────────────────────────────────────
            //
            // Tapable, et c'est le SEUL chemin vers la fiche d'un plat
            // pour qui n'a ni droit d'édition ni droit de suppression :
            // le menu ⋮ ne s'affiche pas pour lui. Or c'est le serveur
            // qui doit lire la composition d'un plat quand le client
            // demande ce qu'il y a dedans.
            Expanded(
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(8),
                // Marges = celles que compte `menuTileHeight` : 8 en haut, 4
                // en bas. Les changer ici sans les changer là-bas fait
                // déborder le bloc.
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      2, kMenuTextTop, 2, kMenuTextBottom),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySmBold.copyWith(
                            color: available
                                ? cs.onSurface
                                : cs.onSurfaceVariant),
                      ),

                      // ── LIGNE D'ÉTAT ─────────────────────────────
                      // Absente quand le plat est disponible, et c'est
                      // voulu : la grille lui réserve quand même sa
                      // hauteur, et le `Spacer` ci-dessous mange la place
                      // inutilisée. Les cartes gardent donc la même
                      // hauteur sans qu'un trou se creuse sous le nom.
                      if (!available) ...[
                        const SizedBox(height: kMenuNameToState),
                        if (retired)
                          Text('Retiré de la vente',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.micro
                                  .copyWith(color: cs.onSurfaceVariant))
                        else
                          // TAPABLE pour l'admin, et c'est le point :
                          // rendre un plat indisponible est un geste
                          // réfléchi qui passe par le menu ⋮, mais le
                          // remettre à la carte arrive dans la minute — un
                          // arrivage, une erreur de manipulation. Le chemin
                          // le plus court sert le cas le plus fréquent. Un
                          // appui long serait introuvable sur le web, comme
                          // l'a déjà tranché le Plan de salle.
                          //
                          // DEUX causes d'indisponibilité, deux remèdes :
                          // un plat ÉPUISÉ est resté `enabled` avec un
                          // compteur à zéro — rebasculer l'interrupteur ne
                          // ferait rien, il faut lui rendre du stock. Un
                          // plat retiré du jour, lui, se rallume.
                          InkWell(
                            onTap: isAdmin
                                ? (avail.isSoldOut
                                    ? onEditCount
                                    : () => onToggleDispo(true))
                                : null,
                            borderRadius: BorderRadius.circular(6),
                            child: Text(
                              // Les deux libellés finissent par
                              // « aujourd'hui » : ce sont des états du
                              // jour, qui tomberont demain matin, et leur
                              // premier mot dit le remède. Épuisé : il
                              // manque du stock. Retiré : il manque une
                              // décision. « Retiré aujourd'hui » se
                              // distingue ainsi de « Retiré de la vente »,
                              // qui est le retrait permanent.
                              avail.isSoldOut
                                  ? 'Épuisé aujourd’hui'
                                  : 'Retiré aujourd’hui',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              // LE TOKEN SUIT SON FOND, et c'est la seule
                              // règle : `warningText` ici, sur la surface
                              // claire de la carte (6,7:1 en clair, ~9:1 en
                              // sombre) ; `warning` sur la pastille de
                              // stock, posée sur un voile noir, où
                              // `warningText` ne tiendrait que 2,2:1.
                              // Ce n'est pas « toujours la variante Text » :
                              // `warning` est calibré pour un fond sombre
                              // ou une icône, `warningText` pour un fond
                              // clair. Même règle pour `danger` et
                              // `success`.
                              style: AppTextStyles.microBold
                                  .copyWith(color: sem.warningText),
                            ),
                          ),
                      ],
                      const Spacer(),

                      // ── LE PRIX, L'ANCRE ─────────────────────────
                      //
                      // Le plus gros texte de la tuile — `subtitle` (16)
                      // semi-gras, unité en petit gris — parce que c'est ce
                      // qu'on lit en premier. En texte primaire et non en
                      // couleur de marque : sur Midnight en sombre, la
                      // primaire ne fait que 1,93:1 (cf. `docs/backlog.md`).
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: RestoAmountText(
                          product.priceSellPos,
                          style: AppTextStyles.subtitle.copyWith(
                              fontWeight: FontWeight.w600,
                              color: available
                                  ? cs.onSurface
                                  : AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
      ),
    );
  }
}

/// Pastille de stock du jour, coin haut gauche de la photo.
///
/// Le compteur vivait dans une barre de contrôle en travers de la photo, à
/// côté d'un interrupteur de 22 px. Il revient sur l'image, mais SEUL et en
/// lecture seule : c'est une information, pas un réglage. Le réglage est resté
/// dans le menu ⋮.
class _StockBadge extends StatelessWidget {
  /// `∞` quand le stock n'est pas compté, sinon le nombre restant.
  final String value;
  final bool soldOut;

  const _StockBadge({required this.value, required this.soldOut});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    // LE TOKEN SUIT SON FOND : sur ce voile noir, `warning` tient 7,0:1 en
    // clair et 8,9:1 en sombre, quand `warningText` — qui est pourtant le bon
    // choix dans le bloc texte, sur surface claire — tomberait à 2,2:1.
    final fg = soldOut ? sem.warning : Colors.white;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: _kBadgeVeil),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Le point dit l'état sans mot : vert tant qu'il reste à servir,
          // ambre quand il n'y a plus rien. Il double le code couleur du
          // chiffre pour ceux qui distinguent mal les deux teintes.
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: soldOut ? sem.warning : sem.success,
            ),
          ),
          const SizedBox(width: 5),
          Text(value, style: AppTextStyles.microBold.copyWith(color: fg)),
        ],
      ),
    );
  }
}

/// Menu ⋮ au coin de la photo : dispo du jour · stock · modifier · supprimer.
///
/// Même parti pris que le Plan de salle : un seul point d'entrée discret pour
/// les actions qui touchent à la fiche, à l'écart des gestes de service (tap =
/// ouvrir, bouton d'ajout = panier). Sans lui, retirer un plat obligeait à
/// ouvrir la fiche et à la faire défiler jusqu'à son dernier bouton.
///
/// Il porte la DISPO DU JOUR et le STOCK DU JOUR, qui occupaient jadis une
/// barre de contrôle en travers de l'image — un interrupteur miniature et un
/// compteur éditable. Ce sont des réglages : leur place est dans un menu, pas
/// en travers de ce qu'on regarde. Seule la LECTURE du stock est restée sur la
/// photo, dans sa pastille.
///
/// La remise à la carte, elle, reste accessible d'un seul tap sur la ligne
/// d'état sous le nom : c'est le geste pressé, il ne passe pas par ici.
///
/// Il revient sur la photo maintenant qu'elle occupe le plein cadre, et
/// reprend donc le voile à 85 % de la pastille de stock : sans lui, l'icône
/// disparaîtrait sur une assiette blanche. La contrainte de 22 px l'emporte sur
/// le minimum de 48 px d'`IconButton` — `ConstrainedBox` clampe les siennes sur
/// celles du parent — sans quoi la pastille déborderait de la photo.
class _DishMenuBtn extends StatelessWidget {
  /// `null` = droit absent → l'entrée n'est pas proposée. Un menu qui montre
  /// une option grisée invite à demander pourquoi ; un menu qui ne la montre
  /// pas ne pose pas la question.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onToggleDispo;
  final VoidCallback? onEditCount;

  /// Sert au seul libellé de l'entrée : « Rendre indisponible » ou « Remettre
  /// à la carte ». Dire l'action plutôt que l'état évite l'ambiguïté d'un
  /// interrupteur, dont on ne sait jamais s'il montre ce qui est ou ce qui
  /// arrivera si on le touche.
  final bool dispoEnabled;

  const _DishMenuBtn({
    required this.onEdit,
    required this.onDelete,
    required this.onToggleDispo,
    required this.onEditCount,
    required this.dispoEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return PopupMenuButton<int>(
      tooltip: 'Actions sur le plat',
      padding: EdgeInsets.zero,
      splashRadius: _kBadgeDot / 2,
      iconSize: _kBadgeDot,
      constraints: const BoxConstraints(minWidth: 210),
      icon: Container(
        width: _kBadgeDot,
        height: _kBadgeDot,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: _kBadgeVeil),
        ),
        alignment: Alignment.center,
        // Blanc sur ce voile : 15:1, quelle que soit la photo dessous. Le
        // token de thème, lui, dépendrait du mode et non du fond réel.
        child: const Icon(Icons.more_vert_rounded,
            size: 15, color: Colors.white),
      ),
      onSelected: (v) {
        switch (v) {
          case 0:
            onEdit?.call();
          case 1:
            onDelete?.call();
          case 2:
            onToggleDispo?.call();
          case 3:
            onEditCount?.call();
        }
      },
      itemBuilder: (_) => [
        if (onToggleDispo != null)
          PopupMenuItem<int>(
            value: 2,
            height: 40,
            child: Row(children: [
              Icon(
                  dispoEnabled
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 16),
              const SizedBox(width: 10),
              Text(dispoEnabled ? 'Rendre indisponible' : 'Remettre à la carte',
                  style: AppTextStyles.bodySm),
            ]),
          ),
        if (onEditCount != null)
          const PopupMenuItem<int>(
            value: 3,
            height: 40,
            child: Row(children: [
              Icon(Icons.inventory_2_outlined, size: 16),
              SizedBox(width: 10),
              Text('Stock du jour', style: AppTextStyles.bodySm),
            ]),
          ),
        if (onEdit != null)
          const PopupMenuItem<int>(
            value: 0,
            height: 40,
            child: Row(children: [
              Icon(Icons.edit_outlined, size: 16),
              SizedBox(width: 10),
              Text('Modifier', style: AppTextStyles.bodySm),
            ]),
          ),
        if (onDelete != null)
          PopupMenuItem<int>(
            value: 1,
            height: 40,
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, size: 16, color: sem.danger),
              const SizedBox(width: 10),
              Text('Supprimer',
                  style: AppTextStyles.bodySm.copyWith(color: sem.dangerText)),
            ]),
          ),
      ],
    );
  }
}
