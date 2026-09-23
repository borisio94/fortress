import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/services/stock_item_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../features/caisse/domain/entities/sale_item.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/restaurant_table.dart';
import '../../domain/entities/stock_item.dart';
import '../../domain/courier_pay.dart';
import '../../domain/order_attach.dart';
import '../../domain/table_drift.dart';
import 'courier_sheet.dart';

/// ENREGISTREMENT D'UNE COMMANDE prise depuis le Menu — Module 3 du flux.
///
/// Étape 1 : type de service. Étape 2 : ce que ce type exige, et rien d'autre
/// — une table et des couverts sur place, un nom et un numéro de retrait au
/// comptoir. Les deux étapes vivent dans LA MÊME feuille : le canevas proscrit
/// la navigation vers de nouvelles pages, et un service qui prend trente
/// commandes à l'heure ne peut pas traverser deux écrans à chaque fois.
///
/// TROIS TYPES : sur place, à emporter, à livrer. La livraison, longtemps
/// exclue, a été rouverte — mais volontairement SANS le circuit e-commerce
/// (quartiers tarifés, partenaire-livreur, transferts de stock) : on saisit
/// une adresse et des frais, point. Ce circuit-là a ses propres écrans et son
/// propre suivi ; l'importer ici alourdirait la prise de commande pour un
/// besoin qui tient en deux champs.
///
/// La commande est créée PUIS envoyée en préparation dans le même geste, comme
/// le prescrit le canevas : le bouton s'appelle « Envoyer en préparation », pas
/// « Enregistrer ». C'est la DERNIÈRE étape de la prise de commande — après
/// elle, le bon est à la fois sur l'écran Préparation et dans la page
/// Commandes. Statut `scheduled` + `sentToKitchen` : le stock n'est décrémenté
/// qu'à l'encaissement.
///
/// « Préparation » et non « cuisine » : un chawarma ou une glace ne passent pas
/// par le piano, et nommer l'étape d'après un seul département laissait croire
/// qu'il en faudrait une par poste.
///
/// Retourne la commande créée ET l'écart constaté sur la table, `null` si
/// l'opérateur a renoncé.
///
/// UN ENREGISTREMENT ET NON LA SEULE COMMANDE, pour que le compilateur oblige
/// l'appelant à regarder `drift`. Deux serveurs travaillent sur le même plan
/// de salle : si la table a changé pendant la saisie, la commande part quand
/// même — on ne bloque pas un service — mais l'écran doit le DIRE. Rendre la
/// commande seule aurait laissé ce message facultatif, c'est-à-dire absent.
/// Voir `table_drift.dart`.
Future<({Sale order, String? drift})?> showOrderTypeSheet({
  required BuildContext context,
  required String shopId,
  required List<SaleItem> items,
  String? tabLabel,
  String? notes,
  /// Canal déjà choisi en amont (`dine_in` · `takeaway` · `delivery`) — la
  /// feuille s'ouvre alors directement sur sa section. `null` = la feuille
  /// pose la question comme avant. Toute autre valeur est ignorée.
  String? initialOrderType,

  /// AJOUT À UNE TABLE DÉJÀ OUVERTE — l'identifiant de cette table.
  ///
  /// Renseigné, la feuille ne pose plus AUCUNE des quatre questions dont la
  /// réponse est connue : le type est « sur place », la table est celle-ci, le
  /// compte est [tabLabel], et les couverts ne bougent pas. Il ne reste que
  /// l'envoi. C'est tout l'objet du constat n° 7 : un dessert coûtait le même
  /// parcours qu'une commande entière.
  ///
  /// Si la table n'existe plus — libérée pendant que le serveur composait sa
  /// sélection —, la feuille retombe sur le parcours complet plutôt que
  /// d'échouer : les plats sont dans le panier, il faut pouvoir les servir.
  String? initialTableId,
}) =>
    showAdaptiveFormSheet<({Sale order, String? drift})>(
      context: context,
      builder: (_) => _OrderTypeSheet(
        shopId: shopId,
        items: items,
        tabLabel: tabLabel,
        notes: notes,
        initialOrderType: initialOrderType,
        initialTableId: initialTableId,
      ),
    );

/// Les trois canaux de service. Chacun correspond à un `Sale.orderType` :
/// `dine_in`, `takeaway`, `delivery`.
enum _ServiceType { dineIn, takeaway, delivery }

class _OrderTypeSheet extends StatefulWidget {
  final String shopId;
  final List<SaleItem> items;
  final String? tabLabel;
  final String? notes;
  final String? initialOrderType;
  final String? initialTableId;

  const _OrderTypeSheet({
    required this.shopId,
    required this.items,
    this.tabLabel,
    this.notes,
    this.initialOrderType,
    this.initialTableId,
  });

  @override
  State<_OrderTypeSheet> createState() => _OrderTypeSheetState();
}

class _OrderTypeSheetState extends State<_OrderTypeSheet> {
  _ServiceType? _type;

  // ── Sur place ──────────────────────────────────────────────────────────
  RestaurantTable? _table;
  int _covers = 1;

  /// Ces plats REJOIGNENT une addition en cours au lieu d'en ouvrir une.
  ///
  /// Posé une fois dans `initState`, jamais ensuite : le rattachement n'est
  /// pas un mode qu'on active à l'écran, c'est la façon dont la feuille a été
  /// ouverte. Il gouverne trois choses — le titre, la disparition du choix de
  /// table et de couverts, et le calcul des couverts à l'envoi.
  bool _attaching = false;

  /// Ce que la table a fait pendant qu'on remplissait la feuille.
  ///
  /// `null` dans l'immense majorité des cas — et alors on ne dit rien : un
  /// message à chaque commande cesserait d'être lu au bout d'un service.
  String? _drift;

  // ── À emporter ET à livrer ─────────────────────────────────────────────
  // Les trois premiers champs servent aux deux canaux : le comptoir crie un
  // nom, le livreur en a besoin sur son bon.
  final _nameCtrl = TextEditingController();
  final _pickupCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  // ── À livrer seulement ─────────────────────────────────────────────────
  final _addressCtrl = TextEditingController();
  final _feeCtrl = TextEditingController();

  /// Ce que reçoit le LIVREUR. Distinct des frais : l'établissement peut en
  /// garder une part. Pré-rempli au montant des frais, remis à zéro dès qu'un
  /// salarié est choisi — son coût est déjà dans la paie.
  final _payCtrl = TextEditingController();

  /// Le livreur est-il payé du TIROIR ?
  ///
  /// Décide si le versement pèse sur la clôture de caisse. Un paiement par
  /// Mobile Money sort de la banque, pas du tiroir : le compter comme espèces
  /// ferait apparaître un manquant au comptage du soir. Espèces par défaut,
  /// parce que c'est ainsi qu'on paie un voisin qui rend service.
  bool _payIsCash = true;

  /// Livreur retenu à la prise de commande — OBLIGATOIRE.
  ///
  /// Une commande à livrer sans porteur désigné n'est la responsabilité de
  /// personne : elle attend au passe sans que quiconque sache qu'elle est pour
  /// lui. Le bouton « Assigner un livreur » de la carte reste disponible pour
  /// en CHANGER, plus pour combler un oubli.
  CourierChoice? _courier;

  // ── À emporter : emballages ────────────────────────────────────────────
  //
  // Le comptoir ne demande plus ni nom ni téléphone : il emballe. Ce que le
  // serveur doit choisir à ce moment-là, c'est la barquette ou le sachet, et
  // leur prix s'ajoute au total. Le repère de la commande reste le numéro de
  // retrait, attribué tout seul.
  late final List<StockItem> _packagingItems =
      StockItemService.sellable(widget.shopId);

  /// Quantité retenue par emballage. Plusieurs à la fois : une commande part
  /// souvent en deux barquettes et un sachet.
  final Map<String, int> _packaging = {};

  int get _packagingTotal => _packaging.entries.fold<int>(
      0,
      (sum, e) =>
          sum +
          e.value *
              (_packagingItems
                  .firstWhere((i) => i.id == e.key)
                  .sellingPrice));

  bool _saving = false;
  String? _error;

  /// Couverts DÉJÀ assis à une table. Une table libre n'en porte aucun ;
  /// occupée sans couverts renseignés, on la suppose pleine — mieux vaut
  /// masquer une table disponible que d'y asseoir des clients sur les genoux
  /// des précédents.
  int _seated(RestaurantTable t) =>
      t.isFree ? 0 : (t.covers ?? t.capacity);

  /// Places encore libres à cette table.
  int _remaining(RestaurantTable t) {
    final left = t.capacity - _seated(t);
    return left < 0 ? 0 : left;
  }

  /// Tables pouvant accueillir la tablée en cours.
  ///
  /// Ce n'est PLUS « les tables libres » : une table de huit dont cinq places
  /// sont prises reste bonne pour trois convives, et l'écarter revenait à
  /// refuser des clients devant des chaises vides. C'est le nombre de couverts
  /// demandé qui filtre, et il se recalcule à chaque appui sur ⊕ — les tables
  /// trop justes disparaissent alors d'elles-mêmes.
  List<RestaurantTable> get _availableTables => RestaurantTableService
      .tablesForShop(widget.shopId)
      .where((t) => _remaining(t) >= _covers && _remaining(t) > 0)
      .toList();

  /// Plus grande tablée plaçable, toutes tables confondues — borne haute du
  /// compteur. Sans elle, on pourrait monter à un nombre de couverts que
  /// AUCUNE table ne peut recevoir, et se retrouver devant une liste vide sans
  /// comprendre pourquoi.
  int get _maxSeatable {
    var max = 1;
    for (final t in RestaurantTableService.tablesForShop(widget.shopId)) {
      final r = _remaining(t);
      if (r > max) max = r;
    }
    return max;
  }

  /// Ajuste la sélection après un changement de couverts : une table devenue
  /// trop juste ne peut pas rester cochée en silence.
  void _setCovers(int value) {
    setState(() {
      _covers = value;
      final t = _table;
      if (t != null && _remaining(t) < _covers) _table = null;
    });
  }

  /// `subtotal` et non `unitPrice × quantité` : il honore le prix des
  /// accompagnements (`customPrice`) et la remise de ligne. Un riz à 2 000 F
  /// avec sa sauce s'afficherait sinon au prix du riz nu.
  double get _total =>
      widget.items.fold<double>(0, (s, i) => s + i.subtotal);

  @override
  void initState() {
    super.initState();
    // RATTACHEMENT D'ABORD : il fixe le type lui-même et rend inutile tout ce
    // qui suit.
    final attachId = (widget.initialTableId ?? '').trim();
    if (attachId.isNotEmpty) {
      for (final t in RestaurantTableService.tablesForShop(widget.shopId)) {
        if (t.id != attachId) continue;
        _attaching = true;
        _table = t;
        _applyChoice(_ServiceType.dineIn);
        return;
      }
      // Table introuvable — libérée ou supprimée entre-temps. On NE bloque
      // pas : le panier est plein, et la feuille complète reste le chemin.
    }
    final t = switch (widget.initialOrderType) {
      'dine_in' => _ServiceType.dineIn,
      'takeaway' => _ServiceType.takeaway,
      'delivery' => _ServiceType.delivery,
      _ => null, // absent ou inconnu → la feuille pose la question
    };
    if (t != null) _applyChoice(t);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _pickupCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    _feeCtrl.dispose();
    _payCtrl.dispose();
    super.dispose();
  }

  void _choose(_ServiceType type) => setState(() => _applyChoice(type));

  /// Corps de [_choose] SANS `setState`, pour être appelable depuis
  /// `initState` — la pré-sélection venue du panier doit être en place au
  /// premier rendu, sinon la feuille clignote de la question vers la section.
  void _applyChoice(_ServiceType type) {
    _type = type;
    _error = null;
    if (type != _ServiceType.dineIn && _pickupCtrl.text.isEmpty) {
      // Le libellé du compte saisi au panier fait un meilleur repère qu'un
      // numéro anonyme quand il existe — « M. Ali » se crie mieux que « R7 ».
      final tab = (widget.tabLabel ?? '').trim();
      _pickupCtrl.text = tab.isNotEmpty
          ? tab
          : RestaurantOrderService.nextPickupNumber(widget.shopId);
    }
  }

  /// Renvoie vers le Plan de salle, SEUL endroit où une table se crée.
  ///
  /// Rouvrir le formulaire de table ici aurait été plus court d'un tap, mais
  /// c'est ainsi qu'on se retrouve avec des tables créées à la volée pendant
  /// le coup de feu, mal nommées et jamais rangées. La salle se dessine une
  /// fois, au calme, dans son écran.
  void _goToFloorPlan() {
    Navigator.of(context).pop();
    context.push('/shop/${widget.shopId}/restaurant/tables');
  }

  /// Facture les emballages retenus et décrémente leur stock.
  ///
  /// Deux effets qui vont ensemble, dans cet ordre : le STOCK d'abord, c'est
  /// le fait matériel — la barquette est partie, qu'on parvienne ou non à la
  /// facturer. Puis la ligne de FRAIS, qui s'ajoute au total conformément à la
  /// règle « plus rien n'est absorbé par la boutique ».
  ///
  /// Un emballage qui échoue n'empêche pas les autres : mieux vaut une facture
  /// partielle qu'une commande bloquée au comptoir.
  Future<Sale> _applyPackaging(Sale order) async {
    var current = order;
    for (final entry in _packaging.entries) {
      if (entry.value <= 0) continue;
      final item = _packagingItems.firstWhere((i) => i.id == entry.key);
      final qty = entry.value;
      try {
        await StockItemService.consume(
            widget.shopId, item.id, qty.toDouble());
        if (item.sellingPrice > 0) {
          current = await RestaurantOrderService.addFee(
            current,
            label: qty > 1 ? '${item.name} ×$qty' : item.name,
            amount: (item.sellingPrice * qty).toDouble(),
          );
        }
      } catch (e) {
        debugPrint('[OrderType] emballage ${item.name} : $e');
      }
    }
    return current;
  }

  void _bumpPackaging(StockItem item, int delta) {
    setState(() {
      final next = (_packaging[item.id] ?? 0) + delta;
      if (next <= 0) {
        _packaging.remove(item.id);
      } else {
        _packaging[item.id] = next;
      }
    });
  }

  /// Frais de livraison saisis. Virgule tolérée : un clavier téléphone la
  /// propose avant le point.
  double get _feeValue =>
      double.tryParse(_feeCtrl.text.trim().replaceAll(',', '.')) ?? 0;

  /// Ce qui sera versé au livreur, tel que saisi.
  double get _payValue =>
      double.tryParse(_payCtrl.text.trim().replaceAll(',', '.')) ?? 0;

  /// Repropose le montant du versement d'après les frais et la nature du
  /// livreur. Appelé à chaque changement de l'un ou de l'autre.
  void _refreshCourierPay() {
    final proposed = courierPayDefault(
      deliveryFee: _feeValue,
      courierIsStaff: _courier?.isStaff ?? false,
    );
    _payCtrl.text = proposed <= 0 ? '' : proposed.toStringAsFixed(0);
  }

  Future<void> _pickCourier() async {
    final choice = await showCourierSheet(
      context: context,
      shopId: widget.shopId,
      current: _courier?.name,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _courier = choice;
      // UN SALARIÉ REMET LE MONTANT À ZÉRO, tout seul. Le laisser pré-rempli
      // paierait la course deux fois : en espèces ce soir, dans la paie à la
      // quinzaine.
      _refreshCourierPay();
    });
  }

  /// Le bon peut-il partir en préparation ?
  ///
  /// SUR PLACE, il faut une table — et pas seulement « des tables existent » :
  /// il faut qu'une soit CHOISIE. Sans elle, la commande partirait en cuisine
  /// sans que personne sache où servir, et l'addition n'aurait aucune table à
  /// rattacher. Le bouton est donc grisé plutôt que de laisser cliquer pour
  /// répondre « choisis la table » — un refus qu'on peut annoncer avant le
  /// geste ne doit pas attendre le geste.
  ///
  /// Un établissement qui n'a encore AUCUNE table tombe dans le même cas : la
  /// section propose alors « Ouvrir le plan de salle », seul endroit où une
  /// table se crée.
  ///
  /// Les autres canaux gardent leurs contrôles dans [_confirm] : le nom, le
  /// téléphone et l'adresse d'une livraison se saisissent au clavier, et griser
  /// le bouton pendant la frappe le ferait clignoter à chaque caractère.
  bool get _canConfirm =>
      _type != _ServiceType.dineIn || _table != null;

  Future<void> _confirm() async {
    if (_saving) return;
    setState(() => _error = null);

    // Contrôles AVANT de passer en « enregistrement » : sinon un champ oublié
    // laisserait le bouton tourner sur place.
    if (_type == _ServiceType.dineIn && _table == null) {
      setState(() => _error = 'Choisis la table du client.');
      return;
    }
    // Le nom n'est exigé qu'en LIVRAISON : le livreur doit savoir chez qui il
    // va. Au comptoir, le numéro de retrait suffit à appeler le client.
    if (_type == _ServiceType.delivery && _nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Le nom du client est obligatoire.');
      return;
    }
    if (_type == _ServiceType.delivery) {
      // Sans telephone ni adresse, le livreur part a l'aveugle : c'est la
      // commande qui revient, pas le client.
      if (_phoneCtrl.text.trim().isEmpty) {
        setState(() => _error = 'Le telephone est obligatoire pour livrer.');
        return;
      }
      if (_addressCtrl.text.trim().isEmpty) {
        setState(() => _error = 'Indique l\'adresse de livraison.');
        return;
      }
      // Une commande à livrer sans porteur désigné n'est la responsabilité de
      // personne : elle attend au passe sans que quiconque sache qu'elle est
      // pour lui.
      if (_courier == null) {
        setState(() => _error = 'Choisis le livreur qui portera la commande.');
        return;
      }
    }

    setState(() => _saving = true);
    try {
      Sale order;
      if (_type == _ServiceType.dineIn) {
        // LA TABLE EST RELUE ICI, et ce n'est pas un détail.
        //
        // `_table` est l'objet capturé à l'OUVERTURE de la feuille. Entre-temps,
        // l'autre serveur a pu ouvrir la même table : le temps réel le lui a
        // dit, mais ce champ-là, lui, ne bouge pas. Le calcul des couverts se
        // faisait donc sur un instantané périmé — B choisit une table libre, A
        // l'ouvre pour 4, B valide, et `0 + 3` efface les quatre couverts de A.
        //
        // `orElse` rend l'instantané : une table supprimée pendant la saisie
        // est un cas si rare qu'échouer ici coûterait plus que d'écrire la
        // commande sur ce qu'on avait. Elle part au push, elle reviendra.
        final snapshot = _table!;
        final live = RestaurantTableService.tablesForShop(widget.shopId)
            .firstWhere((t) => t.id == snapshot.id, orElse: () => snapshot);
        // L'écart se constate AVANT l'écriture, sur les deux états, et se dira
        // après. Voir `table_drift.dart`.
        _drift = tableDriftMessage(
          tableName: live.name,
          seatedBefore: _seated(snapshot),
          seatedAfter: _seated(live),
        );
        // LES COUVERTS NE SE CALCULENT PLUS ICI. La règle distingue une
        // NOUVELLE tablée d'un AJOUT, et c'est une distinction qui n'existait
        // pas : `_seated + _covers` rejoué pour un dessert aurait ajouté un
        // couvert par article commandé en cours de repas. Voir
        // `order_attach.dart`, et le test qui l'épingle.
        final c = coversForTableOrder(
          attaching: _attaching,
          seated: _seated(live),
          newCovers: _covers,
        );
        // `saveTableOrder` occupe la table, pose les couverts et l'heure
        // d'ouverture au passage — pas besoin d'un `openService` séparé, qui
        // ferait deux écritures pour le même fait.
        order = await RestaurantOrderService.saveTableOrder(
          table: live,
          items: widget.items,
          covers: c.orderCovers,
          tableCovers: c.tableCovers,
          tabLabel: (widget.tabLabel ?? '').trim().isEmpty
              ? null
              : widget.tabLabel!.trim(),
          notes: widget.notes,
        );
      } else if (_type == _ServiceType.delivery) {
        order = await RestaurantOrderService.saveDeliveryOrder(
          shopId: widget.shopId,
          items: widget.items,
          tabLabel: _pickupCtrl.text.trim(),
          clientName: _nameCtrl.text.trim(),
          clientPhone: _phoneCtrl.text.trim(),
          address: _addressCtrl.text.trim(),
          deliveryFee: _feeValue,
          courierPay: _payValue,
          courierPayIsCash: _payIsCash,
          courier: _courier?.label,
          notes: widget.notes,
        );
      } else {
        order = await RestaurantOrderService.saveTakeawayOrder(
          shopId: widget.shopId,
          items: widget.items,
          tabLabel: _pickupCtrl.text.trim(),
          // Plus de nom saisi : le numéro de retrait fait le repère, et
          // `saveTakeawayOrder` retombe dessus quand le nom est vide.
          notes: widget.notes,
        );
        order = await _applyPackaging(order);
      }

      // Créer puis envoyer : le canevas ne connaît pas d'état intermédiaire
      // entre « commande prise » et « en préparation ».
      await RestaurantOrderService.sendToKitchen(order);
      if (mounted) Navigator.of(context).pop((order: order, drift: _drift));
    } catch (e) {
      // Sans ce filet, l'échec laisserait le bouton tourner indéfiniment et
      // l'opérateur ne saurait pas s'il doit ressaisir la commande.
      debugPrint('[OrderType] échec création : $e');
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Enregistrement impossible. Réessayez.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;

    return AdaptiveFormFrame(
      title: _attaching
          ? 'Ajouter des plats'
          : switch (_type) {
              null => 'Type de commande',
              _ServiceType.dineIn => 'Manger sur place',
              _ServiceType.takeaway => 'À emporter',
              _ServiceType.delivery => 'À livrer',
            },
      subtitle: '${widget.items.length} article'
          '${widget.items.length > 1 ? 's' : ''} · '
          '${CurrencyFormatter.format(_total)}',
      icon: switch (_type) {
        null => Icons.receipt_long_rounded,
        _ServiceType.dineIn => Icons.restaurant_rounded,
        _ServiceType.takeaway => Icons.takeout_dining_outlined,
        _ServiceType.delivery => Icons.local_shipping_outlined,
      },
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_type == null)
              ..._buildTypeChoice()
            else ...[
              // Revenir sur le type sans tout ressaisir : l'erreur de tap est
              // fréquente, et refermer la feuille perdrait la commande.
              //
              // ABSENT EN RATTACHEMENT : le type n'a pas été choisi ici, il
              // découle de la table visée. Proposer d'en changer laisserait
              // croire qu'on peut emporter des plats commandés pour une
              // table qui, elle, reste occupée.
              if (!_attaching)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                            _type = null;
                            _error = null;
                          }),
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('Changer de type'),
                ),
              ),
              const SizedBox(height: 4),
              if (_type == _ServiceType.dineIn)
                ..._buildDineIn(cs)
              else if (_type == _ServiceType.takeaway)
                ..._buildTakeaway(cs)
              else
                ..._buildCounter(true),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style:
                        AppTextStyles.captionHint.copyWith(color: sem.danger)),
              ],
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Envoyer en préparation',
                icon: Icons.local_fire_department_rounded,
                fullWidth: true,
                isLoading: _saving,
                enabled: _canConfirm,
                onTap: _confirm,
              ),
              // Un bouton grisé sans raison affichée se lit comme une panne.
              // Le message n'apparaît QUE si la salle a des tables : quand il
              // n'y en a aucune, la section a déjà expliqué qu'il faut passer
              // par le plan de salle, et le répéter ici ferait deux fois la
              // même phrase à trois lignes d'écart.
              if (!_canConfirm && _availableTables.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Choisissez la table du client pour continuer.',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.captionHint),
              ],
            ],
          ],
        ),
      ),
    );
  }

  // ── Étape 1 ────────────────────────────────────────────────────────────

  List<Widget> _buildTypeChoice() => [
        Text('Où le client mange-t-il ?', style: AppTextStyles.captionHint),
        const SizedBox(height: 14),
        _TypeCard(
          icon: Icons.restaurant_rounded,
          title: 'Manger sur place',
          subtitle: 'Table et couverts — la table passe occupée',
          onTap: () => _choose(_ServiceType.dineIn),
        ),
        const SizedBox(height: 10),
        _TypeCard(
          icon: Icons.takeout_dining_outlined,
          title: 'À emporter',
          subtitle: 'Commandé sur place, emporté par le client',
          onTap: () => _choose(_ServiceType.takeaway),
        ),
        const SizedBox(height: 10),
        _TypeCard(
          icon: Icons.local_shipping_outlined,
          title: 'À livrer',
          subtitle: 'Portée au client — téléphone et adresse requis',
          onTap: () => _choose(_ServiceType.delivery),
        ),
      ];

  // ── Étape 2A — sur place ───────────────────────────────────────────────

  List<Widget> _buildDineIn(ColorScheme cs) {
    // ── RATTACHEMENT : plus rien à demander ─────────────────────────────
    //
    // Ni table — elle est visée —, ni couverts — les convives sont assis
    // depuis le plat principal. Un récapitulatif à la place, parce qu'un
    // formulaire qui ne demande rien doit au moins dire OÙ ça part : sans
    // lui, « Envoyer en préparation » serait un bouton sans destination
    // visible.
    final attached = _table;
    if (_attaching && attached != null) {
      final sem = Theme.of(context).semantic;
      return [
        const AppFieldLabel('Ces plats rejoignent'),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: sem.elevatedSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: sem.borderSubtle),
          ),
          child: Row(children: [
            Icon(Icons.table_restaurant_outlined,
                size: 18, color: cs.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(attached.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyBold
                          .copyWith(color: cs.onSurface)),
                  Text(
                      // Le libellé BRUT peut être vide : c'est le compte
                      // « Sans nom », et il en existe un par table. Voir
                      // `RestaurantTab.displayLabel`.
                      (widget.tabLabel ?? '').trim().isEmpty
                          ? 'Sans nom'
                          : widget.tabLabel!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption),
                ],
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Text(
            'Les couverts de la table ne changent pas : ces convives sont '
            'déjà comptés.',
            style: AppTextStyles.captionHint),
      ];
    }
    final tables = _availableTables;
    if (tables.isEmpty) {
      return [
        Text(
            _covers > 1
                ? 'Aucune table ne peut recevoir $_covers couverts. Réduisez '
                    'la tablée, libérez une table, ou ajoutez-en une depuis '
                    'le plan de salle.'
                : 'Aucune place libre. Libérez une table occupée, ou '
                    'ajoutez-en une depuis le plan de salle.',
            style: AppTextStyles.captionHint),
        const SizedBox(height: 12),
        AppPrimaryButton(
          label: 'Ouvrir le plan de salle',
          icon: Icons.table_restaurant_outlined,
          fullWidth: true,
          onTap: _goToFloorPlan,
        ),
      ];
    }
    return [
      const AppFieldLabel('Table', required: true),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in tables)
            _TableChip(
              table: t,
              remaining: _remaining(t),
              partial: !t.isFree,
              selected: _table?.id == t.id,
              // On NE touche PLUS aux couverts en choisissant la table : c'est
              // désormais la tablée qui commande le filtrage, la remettre à la
              // capacité de la table effacerait ce que l'opérateur vient de
              // saisir.
              onTap: () => setState(() {
                _table = t;
                _error = null;
              }),
            ),
        ],
      ),
      const SizedBox(height: 18),
      const AppFieldLabel('Nombre de couverts'),
      const SizedBox(height: 4),
      Row(children: [
        IconButton(
          onPressed: _covers > 1 ? () => _setCovers(_covers - 1) : null,
          icon: const Icon(Icons.remove_circle_outline_rounded),
        ),
        SizedBox(
          width: 96,
          child: Text('$_covers couvert${_covers > 1 ? 's' : ''}',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
        ),
        IconButton(
          // Borné par la plus grande tablée encore plaçable, pas par la table
          // choisie : on doit pouvoir monter les couverts AVANT de choisir, et
          // voir la liste se restreindre au fur et à mesure.
          onPressed: _covers < _maxSeatable
              ? () => _setCovers(_covers + 1)
              : null,
          icon: Icon(Icons.add_circle_outline_rounded, color: cs.primary),
        ),
      ]),
    ];
  }

  // ── Étape 2B — à emporter : les EMBALLAGES ─────────────────────────────
  //
  // Ce que le comptoir a réellement à décider en emballant une commande, ce
  // n'est ni le nom ni le téléphone du client : c'est le contenant. Le nom
  // était demandé puis jamais relu — on appelle le client par son numéro de
  // retrait, attribué tout seul.
  //
  // Plusieurs emballages à la fois : une commande part souvent en deux
  // barquettes et un sachet. Leur prix s'ajoute au total de la commande.

  List<Widget> _buildTakeaway(ColorScheme cs) {
    if (_packagingItems.isEmpty) {
      return [
        Text(
            'Aucun emballage facturable. Créez vos barquettes et vos sachets '
            'dans Finances → Fournitures, avec un prix de vente — c\'est lui '
            'qui les rend proposables ici.',
            style: AppTextStyles.captionHint),
        const SizedBox(height: 10),
        Text('Vous pouvez envoyer la commande sans emballage.',
            style: AppTextStyles.caption),
      ];
    }
    return [
      Row(children: [
        Expanded(
          child: Text('Emballages',
              style: AppTextStyles.bodySmBold.copyWith(color: cs.onSurface)),
        ),
        Text('Retrait ${_pickupCtrl.text}',
            style: AppTextStyles.caption.copyWith(color: cs.primary)),
      ]),
      const SizedBox(height: 2),
      Text('Ajoutés au total de la commande et retirés de votre stock.',
          style: AppTextStyles.captionHint),
      const SizedBox(height: 10),
      for (final item in _packagingItems)
        _PackagingRow(
          item: item,
          quantity: _packaging[item.id] ?? 0,
          onMinus: () => _bumpPackaging(item, -1),
          onPlus: () => _bumpPackaging(item, 1),
        ),
      if (_packagingTotal > 0) ...[
        const Divider(height: 18),
        Row(children: [
          Expanded(
            child: Text('Total emballages',
                style: AppTextStyles.bodySm.copyWith(color: cs.onSurface)),
          ),
          Text(CurrencyFormatter.format(_packagingTotal.toDouble()),
              style: AppTextStyles.subtitleBold.copyWith(color: cs.primary)),
        ]),
      ],
    ];
  }

  // ── Étape 2C — à livrer ────────────────────────────────────
  //
  // Un seul formulaire pour deux canaux : ils partagent le nom, le repère et
  // le téléphone. La livraison ajoute l'adresse et les frais, et durcit le
  // téléphone — facultatif au comptoir, indispensable pour livrer.

  List<Widget> _buildCounter(bool delivery) => [
        const AppFieldLabel('Nom du client', required: true),
        const SizedBox(height: 8),
        AppField(
          controller: _nameCtrl,
          hint: 'Ex. Awa',
          autofocus: true,
          prefixIcon: Icons.person_outline_rounded,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: 16),
        AppFieldLabel(delivery ? 'Numéro de commande' : 'Numéro de retrait'),
        const SizedBox(height: 8),
        AppField(
          controller: _pickupCtrl,
          hint: 'R1',
          prefixIcon: Icons.confirmation_number_outlined,
        ),
        const SizedBox(height: 16),
        AppFieldLabel('Téléphone', required: delivery),
        const SizedBox(height: 8),
        AppField(
          controller: _phoneCtrl,
          hint: '6 XX XX XX XX',
          keyboardType: TextInputType.phone,
          prefixIcon: Icons.phone_outlined,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        if (delivery) ...[
          const SizedBox(height: 16),
          const AppFieldLabel('Adresse de livraison', required: true),
          const SizedBox(height: 8),
          AppField(
            controller: _addressCtrl,
            hint: 'Quartier, repère, étage…',
            maxLines: 2,
            prefixIcon: Icons.place_outlined,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 16),
          const AppFieldLabel('Frais de livraison'),
          const SizedBox(height: 8),
          AppField(
            controller: _feeCtrl,
            hint: '0',
            numbersOnly: true,
            keyboardType: TextInputType.number,
            prefixIcon: Icons.payments_outlined,
            onChanged: (_) => setState(_refreshCourierPay),
          ),
          const SizedBox(height: 6),
          Text('Ajoutés au total de la commande, et au chiffre d\'affaires.',
              style: AppTextStyles.captionHint),

          // ── Livreur ──────────────────────────────────────────────
          const SizedBox(height: 18),
          const AppFieldLabel('Livreur', required: true),
          const SizedBox(height: 8),
          _CourierTile(
            courier: _courier,
            onTap: _pickCourier,
            onClear: () => setState(() {
              _courier = null;
              _refreshCourierPay();
            }),
          ),

          // ── Versé au livreur ─────────────────────────────────────
          //
          // LE POINT DE CE LOT. Les frais étaient encaissés et le livreur
          // nommé, mais ce qu'il reçoit n'était écrit nulle part — ni en
          // charge, ni en sortie de caisse. Un voisin payé du tiroir
          // apparaissait le soir comme un MANQUANT imputé au caissier.
          if (_courier?.isStaff ?? false) ...[
            const SizedBox(height: 18),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.badge_outlined,
                  size: 15, color: Theme.of(context).semantic.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    'Livreur salarié : rien à verser ici, son coût est déjà '
                    'dans la paie.',
                    style: AppTextStyles.captionHint),
              ),
            ]),
          ] else ...[
            const SizedBox(height: 18),
            const AppFieldLabel('Versé au livreur'),
            const SizedBox(height: 8),
            AppField(
              controller: _payCtrl,
              hint: '0',
              numbersOnly: true,
              keyboardType: TextInputType.number,
              prefixIcon: Icons.local_shipping_outlined,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 6),
            Text(
                _payValue <= 0
                    ? 'Rien de saisi : aucune charge ne sera enregistrée.'
                    : 'Enregistré en dépense « Transport ».',
                style: AppTextStyles.captionHint),
            // ESPÈCES OU NON — la question décide de la clôture de caisse.
            // Un règlement Mobile Money sort de la banque, pas du tiroir.
            if (_payValue > 0) ...[
              const SizedBox(height: 4),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _payIsCash,
                onChanged: (v) => setState(() => _payIsCash = v),
                title: const Text('Payé en espèces, du tiroir',
                    style: AppTextStyles.bodySm),
                subtitle: Text(
                    _payIsCash
                        ? 'Déduit du fond de caisse attendu ce soir.'
                        : 'Hors caisse — Mobile Money, virement, plus tard.',
                    style: AppTextStyles.captionHint),
              ),
            ],
          ],

          // ── Total à encaisser ────────────────────────────────────
          // Plats + livraison. C'est le montant que le client réglera au
          // livreur : l'annoncer ICI évite de le recalculer de tête au
          // moment de confier la commande.
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary
                  .withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              Expanded(
                child: Text('Total à encaisser',
                    style: AppTextStyles.bodySmBold.copyWith(
                        color: Theme.of(context).colorScheme.onSurface)),
              ),
              Text(CurrencyFormatter.format(_total + _feeValue),
                  style: AppTextStyles.subtitleBold.copyWith(
                      color: Theme.of(context).colorScheme.primary)),
            ]),
          ),
        ],
      ];
}

/// Ligne « Livreur » du formulaire de livraison — vide, ou le livreur retenu
/// avec son numéro, qu'on peut retirer d'une croix.
class _CourierTile extends StatelessWidget {
  final CourierChoice? courier;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const _CourierTile({
    required this.courier,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    final c = courier;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: sem.borderSubtle),
        ),
        child: Row(children: [
          Icon(Icons.delivery_dining_outlined,
              size: 18, color: c == null ? null : cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: c == null
                ? const Text('Choisir un livreur',
                    style: AppTextStyles.bodySm)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.bodySmBold
                              .copyWith(color: cs.onSurface)),
                      if (c.phone.trim().isNotEmpty)
                        Text(c.phone.trim(), style: AppTextStyles.caption),
                    ],
                  ),
          ),
          if (c == null)
            const Icon(Icons.chevron_right_rounded, size: 18)
          else
            IconButton(
              onPressed: onClear,
              icon: Icon(Icons.close_rounded, size: 16, color: sem.danger),
              tooltip: 'Retirer',
              visualDensity: VisualDensity.compact,
            ),
        ]),
      ),
    );
  }
}

/// Une ligne d'emballage : nom, prix unitaire, stock restant, compteur.
class _PackagingRow extends StatelessWidget {
  final StockItem item;
  final int quantity;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _PackagingRow({
    required this.item,
    required this.quantity,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;
    // Le stock RESTANT est affiché : sans lui, on facture des barquettes qu'on
    // n'a plus, et l'écart n'apparaît qu'au comptage suivant.
    final remaining = item.quantity - quantity;
    final short = remaining < 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      AppTextStyles.bodySmBold.copyWith(color: cs.onSurface)),
              Text('${item.sellingPrice} F · reste ${_fmtQty(remaining)} '
                  '${item.unit}',
                  style: AppTextStyles.caption
                      .copyWith(color: short ? sem.danger : null)),
            ],
          ),
        ),
        IconButton(
          onPressed: quantity > 0 ? onMinus : null,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
        ),
        SizedBox(
          width: 22,
          child: Text('$quantity',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
        ),
        IconButton(
          onPressed: onPlus,
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.add_circle_outline_rounded,
              size: 20, color: cs.primary),
        ),
      ]),
    );
  }

  static String _fmtQty(double v) =>
      v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

/// Grande cible tactile de l'étape 1 — « 3 boutons bien distincts » du
/// canevas, ramenés à deux.
class _TypeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _TypeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sem.borderSubtle),
        ),
        child: Row(children: [
          Icon(icon, size: 26, color: cs.primary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
                const SizedBox(height: 2),
                Text(subtitle, style: AppTextStyles.caption),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20),
        ]),
      ),
    );
  }
}

/// Une table libre dans la grille de sélection.
class _TableChip extends StatelessWidget {
  final RestaurantTable table;

  /// Places encore libres — c'est CE nombre qui compte au moment de placer des
  /// clients, pas la capacité totale de la table.
  final int remaining;

  /// La table est déjà occupée par une autre tablée. Signalé : on ne s'assoit
  /// pas de la même façon à une table vide qu'à une table partagée.
  final bool partial;
  final bool selected;
  final VoidCallback onTap;

  const _TableChip({
    required this.table,
    required this.remaining,
    required this.partial,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? cs.primary : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? cs.primary : sem.borderSubtle),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(table.name,
                style: AppTextStyles.bodyBold.copyWith(
                    color: selected ? Colors.white : cs.onSurface)),
            // Un point discret marque la table PARTAGÉE : le serveur doit
            // savoir qu'il ajoute une tablée à côté d'une autre, sans quoi il
            // annoncerait « table libre » à des clients qui trouveront des
            // convives installés.
            if (partial) ...[
              const SizedBox(width: 5),
              Icon(Icons.group_rounded,
                  size: 11,
                  color: selected
                      ? Colors.white.withValues(alpha: 0.85)
                      : sem.warning),
            ],
          ]),
          Text(
              partial
                  ? '$remaining libre${remaining > 1 ? 's' : ''} / '
                      '${table.capacity}'
                  : '$remaining pl.',
              style: AppTextStyles.caption.copyWith(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.85)
                      : null)),
        ]),
      ),
    );
  }
}
