part of 'restaurant_tables_page.dart';

// L'en-tête de salle et la carte d'une table.

/// En-tête du plan de salle : son NOM, le décompte en sous-titre, la légende.
///
/// Le nom est revenu le 25/09/2026 (lot Shell) : la barre du haut se tait sur
/// les pages racines du restaurant, et cet écran n'affichait qu'un décompte —
/// sur ordinateur, aucun nom de page.
///
/// PAS DE BOUTON « + TABLE » ICI : la création passe par le bouton flottant
/// (cf. `RestoFab`), seul appel de l'écran. L'état vide garde son propre bouton.
/// SEUIL DE CONTENU (document de design § 8) : à partir de 640 px de
/// CONTENEUR, la légende des statuts tient À DROITE du décompte de salle ; en
/// dessous, elle passe dessous plutôt que d'écraser le décompte.
const double kRoomLegendBesideMin = 640;

class _RoomHeader extends StatelessWidget {
  final String headline;
  final bool wide;

  const _RoomHeader({
    required this.headline,
    required this.wide,
  });

  @override
  Widget build(BuildContext context) {
    // Même en-tête que Stock et Accès à l'app ; la légende à droite sur une
    // ligne large, dessous sinon.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RestoSectionHeader(
            title: 'Plan de salle',
            subtitle: headline,
            trailing: wide ? const _StatusLegend() : null,
          ),
          if (!wide)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: _StatusLegend(),
            ),
        ],
      ),
    );
  }
}

/// Légende des statuts — PETITE, à droite du décompte. Elle informe sans
/// annoncer : c'est le liseré des cartes qui porte la couleur, la légende ne
/// sert qu'à qui la cherche.
class _StatusLegend extends StatelessWidget {
  const _StatusLegend();

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    return Wrap(
      spacing: 10,
      runSpacing: 4,
      children: [
        for (final status in RestaurantTableStatus.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: status.color(semantic),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              // `micro` (10) : le plus petit échelon de l'échelle. On
              // n'invente pas un 9 en dur pour un pixel.
              Text(status.label, style: AppTextStyles.microSecondary),
            ],
          ),
      ],
    );
  }
}

/// Ce que la carte montre d'une table, calculé une seule fois.
///
/// Partagé avec l'en-tête : « 2 occupées » en haut doit correspondre aux deux
/// cartes marquées « Occupée » en dessous.
class _TableView {
  final RestaurantTable table;

  /// Statut AFFICHÉ — voir [of].
  final RestaurantTableStatus status;
  final List<RestaurantTab> tabs;
  final double total;

  /// Plats prêts au passe et pas encore apportés.
  final int waiting;

  const _TableView({
    required this.table,
    required this.status,
    required this.tabs,
    required this.total,
    required this.waiting,
  });

  /// Des clients y sont assis : occupée ou en attente d'addition.
  bool get inService =>
      status == RestaurantTableStatus.occupee ||
      status == RestaurantTableStatus.addition;

  factory _TableView.of(String shopId, RestaurantTable table) {
    // Statut DÉDUIT des commandes, pas seulement lu sur la table : une table
    // marquée « libre » alors qu'elle porte des commandes ouvertes (app fermée
    // entre la prise de commande et la mise à jour de la table) affichait un
    // état faux au service. Une réservation, elle, ne se déduit d'aucune
    // commande : ce statut reste celui de la table.
    //
    // `displayStatus` et non `status` : une réservation dont la courtoisie est
    // écoulée retombe sur « Libre ». Sans ça, la carte resterait bleue et
    // marquée « Réservée » alors que la table est de nouveau proposée à la
    // prise de commande — l'écran dirait le contraire du comportement.
    final summary = RestaurantOrderService.tableSummary(table);
    final shown = table.displayStatus;
    final status = summary.count > 0 && shown == RestaurantTableStatus.libre
        ? RestaurantTableStatus.occupee
        : shown;
    return _TableView(
      table: table,
      status: status,
      tabs: RestaurantTabService.tabsForTable(shopId, table.id),
      total: summary.total,
      waiting: RestaurantOrderService.waitingServiceFor(table).length,
    );
  }
}

/// Carte d'état d'une table — INFORMATIVE, 82 px de haut.
///
/// Elle ne réagit pas au tap : toute commande passe par le Menu (panier →
/// « Type de commande »). Seul le ⋮ est cliquable, et il ne touche qu'à la
/// TABLE : addition, comptes, couverts, réservation, libération, suppression.
///
/// ─── QUATRE LIGNES, PAS UN CARRÉ ─────────────────────────────────────────
///
///   1. le nom, et le ⋮ ;
///   2. l'état, et le nombre de COMPTES — « Occupée · 2 comptes » ;
///   3. ce qu'un serveur cherche en passant : « 4 sur 6 · 12 500 F » (clients,
///      places, argent), la capacité d'une table libre, l'heure et le nom
///      d'une réservation ;
///   4. ce qui demande un regard : « À servir », la durée d'ouverture, « client
///      attendu ».
///
/// La carte faisait 245 px de haut autour d'une icône de 38 px — une coche,
/// des personnes — qui occupait un tiers de la surface pour dire ce que la
/// couleur disait déjà. Le LISERÉ GAUCHE la remplace : la grille se scanne par
/// la colonne des liserés.
class _TableCard extends StatelessWidget {
  final _TableView view;
  final VoidCallback onActions;

  const _TableCard({required this.view, required this.onActions});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final table = view.table;
    final status = view.status;
    final accent = status.color(semantic);
    // Le liseré, la bordure et l'icône prennent la couleur d'état ; le TEXTE
    // suit son fond (la teinte d'état) : variante `*Text`, et pour « Réservée »
    // (`info`, sans variante texte) `textSecondary` — une information se dit
    // sans couleur (document de design § 16).
    final accentText = accent == semantic.info
        ? AppColors.textSecondary
        : semantic.textFor(accent);
    final waiting = view.waiting;
    // DEPUIS QUAND CETTE TABLE EST OUVERTE. `null` sur une table libre, et sur
    // une horloge déréglée — voir `table_service_age.dart`.
    //
    // Calculé au build et non rafraîchi par une horloge : la carte se redessine
    // à chaque changement de commande, ce qui suffit très largement pour une
    // durée qu'on lit en minutes puis en heures.
    final open = tableOpenFor(openedAt: table.openedAt, now: DateTime.now());
    final age = open == null ? null : tableServiceOf(open);
    final tabCount = view.tabs.length;
    final line4 = _line4(context, table, waiting, open, age);

    return Material(
      color: status.surface(semantic),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        // Plats prêts au passe : la SEULE information du plan de salle qui
        // appelle une action dans la minute. Elle prend tout le contour, pas
        // seulement une pastille.
        side: waiting > 0
            ? BorderSide(color: semantic.warning, width: 2)
            : BorderSide(color: accent.withValues(alpha: 0.30)),
      ),
      child: Stack(fit: StackFit.expand, children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: kStateStripeWidth, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 6, 2, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // ── 1. Nom + ⋮ ─────────────────────────────────────────
                    Row(children: [
                      Expanded(
                        child: Text(table.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.bodyBold
                                .copyWith(color: cs.onSurface)),
                      ),
                      // Discret mais toujours visible : enfoui derrière un appui
                      // long, il serait introuvable sur le web. Jamais vide : le
                      // menu d'une table libre porte « Réserver ».
                      //
                      // AU DOIGT, ce n'est plus que le DESSIN : la cible est la
                      // zone de 48 px superposée plus bas (lot 2). À la souris,
                      // le bouton de 26 × 22 reste la cible.
                      SizedBox(
                        width: 26,
                        height: 22,
                        child: isTouchPlatform
                            ? Icon(Icons.more_vert_rounded,
                                size: 17,
                                color: cs.onSurface.withValues(alpha: 0.6))
                            : IconButton(
                                onPressed: onActions,
                                icon: Icon(Icons.more_vert_rounded,
                                    size: 17,
                                    color: cs.onSurface.withValues(alpha: 0.6)),
                                tooltip: 'Actions sur la table',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                      ),
                    ]),
                    // ── 2. État + comptes ──────────────────────────────────
                    Row(children: [
                      Flexible(
                        child: Text(status.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                AppTextStyles.captionBold
                                    .copyWith(color: accentText)),
                      ),
                      if (tabCount > 0) ...[
                        const SizedBox(width: 5),
                        _TabPill(
                            count: tabCount,
                            color: accent,
                            textColor: accentText),
                      ],
                    ]),
                    // ── 3. Clients, places, argent ─────────────────────────
                    Text(_line3(table, view),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption),
                    // ── 4. Ce qui demande un regard ────────────────────────
                    if (line4 != null) line4,
                  ],
                ),
              ),
            ),
          ],
        ),
        // ── LA CIBLE DU ⋮ AU DOIGT : 48 × 48, SUPERPOSÉE ──────────────────
        //
        // Pas enveloppée : la tuile a une hauteur FIXE (`mainAxisExtent: 82`,
        // ~70 px de contenu). Porter la rangée du nom à 48 px la ferait monter
        // à ~96 — débordement (vérifié au lot 2, cf. `touch_target.dart`). Posée
        // dans le coin, la zone ne prend aucune place ; elle recouvre la fin du
        // nom, qui ne réagit à rien (la carte n'a pas d'action au tap).
        if (isTouchPlatform)
          Positioned(
            top: 0,
            right: 0,
            width: kMinTouchTarget,
            height: kMinTouchTarget,
            child: Tooltip(
              message: 'Actions sur la table',
              child: InkWell(onTap: onActions),
            ),
          ),
      ]),
    );
  }

  /// « 4 sur 6 · 12 500 F » en service, « 6 places » libre, « 20:00 · Dupont »
  /// réservée.
  ///
  /// « 4 sur 6 » plutôt que « 4 couverts · 2 libres » : clients ET places en
  /// trois caractères. Une table de six occupée par quatre n'est pas pleine,
  /// et c'est ce qu'on cherche du regard en plaçant des clients qui entrent.
  static String _line3(RestaurantTable table, _TableView view) {
    // HEURE SAISIE, jamais la fin de courtoisie : le gérant a noté 20:00,
    // c'est 20:00 qui doit s'afficher — sinon le serveur annonce au client une
    // heure que personne n'a dite.
    if (view.status == RestaurantTableStatus.reservee &&
        table.hasLiveReservation) {
      final name = (table.reservationName ?? '').trim();
      return '${_hhmm(table.reservationTime!)}'
          '${name.isEmpty ? '' : ' · $name'}';
    }
    if (!view.inService) return '${table.capacity} places';
    final covers = table.covers ?? table.capacity;
    final seated = covers > table.capacity ? table.capacity : covers;
    final money =
        view.total > 0 ? ' · ${CurrencyFormatter.format(view.total)}' : '';
    return '$seated sur ${table.capacity}$money';
  }

  /// Quatrième ligne, par ordre d'urgence : un plat attend au passe, puis
  /// l'âge de la table, puis un client en retard sur sa réservation. `null` :
  /// rien à signaler, la carte s'arrête à trois lignes.
  static Widget? _line4(BuildContext context, RestaurantTable table,
      int waiting, Duration? open, TableService? age) {
    final semantic = Theme.of(context).semantic;
    if (waiting > 0) {
      return Text(waiting > 1 ? 'À SERVIR ($waiting)' : 'À SERVIR',
          maxLines: 1,
          style: AppTextStyles.microBold.copyWith(color: semantic.warningText));
    }
    // ── DEPUIS QUAND ──────────────────────────────────────────────────────
    //
    // Une table ouverte depuis dix minutes et une table oubliée depuis
    // vendredi s'affichaient de façon strictement identique. UNE LIGNE, TROIS
    // TONS : une table qui dort n'est pas urgente, elle est anormale — elle
    // doit se remarquer sans couvrir ce qui presse.
    if (open != null && age != null) {
      final caption = AppTextStyles.caption;
      final color = switch (age) {
        TableService.courte => caption.color,
        TableService.longue => semantic.warningText,
        TableService.dormante => semantic.dangerText,
      };
      return Row(children: [
        Icon(
            // L'icône change AUSSI, pas seulement la couleur : une alerte qui
            // ne tient qu'à une teinte n'existe pas pour qui ne distingue pas
            // le rouge.
            age == TableService.dormante
                ? Icons.error_outline_rounded
                : Icons.schedule_rounded,
            size: 11,
            color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            // « oubliée ? » et non « dormante » : le libellé dit au serveur ce
            // qu'il a à VÉRIFIER, pas le nom que le code donne à l'état.
            age == TableService.dormante
                ? '${tableServiceLabel(open)} · oubliée ?'
                : tableServiceLabel(open),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (age == TableService.courte
                    ? AppTextStyles.micro
                    : AppTextStyles.microBold)
                .copyWith(color: color),
          ),
        ),
      ]);
    }
    // L'heure est passée mais la table est ENCORE tenue. C'est le seul état
    // qui ne se lit pas sur le chiffre : sans cette mention, la courtoisie
    // serait invisible.
    if (table.isReservationOverdue) {
      return Text('client attendu',
          style: AppTextStyles.micro.copyWith(color: AppColors.textSecondary));
    }
    return null;
  }

  static String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// Pastille du nombre de comptes : « 2 comptes ».
///
/// Des COMPTES et non des commandes : deux bons envoyés en cuisine pour la
/// même addition ne font qu'un compte, et c'est le compte qu'on encaisse.
class _TabPill extends StatelessWidget {
  final int count;
  final Color color;

  /// Couleur du chiffre : la variante texte de [color] (cf. `accentText`).
  final Color textColor;
  const _TabPill(
      {required this.count, required this.color, required this.textColor});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.receipt_long_rounded, size: 10, color: color),
          const SizedBox(width: 3),
          Text('$count compte${count > 1 ? 's' : ''}',
              maxLines: 1,
              style: AppTextStyles.microBold.copyWith(color: textColor)),
        ]),
      );
}
