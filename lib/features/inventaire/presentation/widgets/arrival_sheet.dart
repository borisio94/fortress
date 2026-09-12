import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/arrival_costing_service.dart';
import '../../../../core/services/arrival_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/back_dated_picker.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/product.dart';
import '../../domain/entities/reception.dart';
import 'arrival_widgets.dart';
import 'new_product_draft_sheet.dart';

// ═════════════════════════════════════════════════════════════════════════════
// Saisie d'un arrivage, appelée depuis l'INVENTAIRE — là où les produits sont
// déjà sous les yeux, au lieu d'une page séparée qui les re-listait.
//
// Deux usages :
//   * ArrivalSheetMode.arrival  — la marchandise entre : quantités, prix
//     d'achat unitaires, frais du lot. Stock et coûts posés d'un coup.
//   * ArrivalSheetMode.costOnly — le stock est déjà là et seule la facture
//     de transport/douane arrive : les frais se répartissent par pièce sur
//     le prix d'achat. C'est ce que déclenche l'action « Frais » sur une
//     sélection de produits.
//
// LA SAISIE DESCEND À LA VARIANTE. Un arrivage ne concerne presque jamais
// toutes les déclinaisons d'un modèle : on reçoit 5 bleues et 2 argentées,
// pas « 7 Poedagar 928 ». Chaque variante porte donc sa propre quantité et
// son propre prix — et le coût atterrit sur la bonne ligne de stock, au lieu
// d'être versé en bloc sur la variante principale.
//
// L'écriture est IMMÉDIATE (pas de brouillon) : quand on saisit, la
// marchandise est déjà devant soi. Un bon validé est archivé pour
// l'historique, consultable dans Stock › Arrivages.
// ═════════════════════════════════════════════════════════════════════════════

enum ArrivalSheetMode { arrival, costOnly }

/// Ouvre la saisie. [preselectedIds] restreint la liste à ces produits (cas
/// de l'action « Frais » sur une sélection) ; sinon tout le catalogue est
/// proposé. Retourne `true` si un bon a été appliqué.
Future<bool?> showArrivalSheet(
  BuildContext context, {
  required String shopId,
  ArrivalSheetMode mode = ArrivalSheetMode.arrival,
  Set<String>? preselectedIds,
  /// Verrouille le mode : l'action « Frais » ne doit pas pouvoir basculer en
  /// entrée de stock par inadvertance sur des produits déjà en rayon.
  bool lockMode = false,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _ArrivalSheet(
      shopId: shopId,
      initialMode: mode,
      preselectedIds: preselectedIds,
      lockMode: lockMode,
    ),
  );
}

/// Une ligne saisissable : une VARIANTE précise, ou le produit lui-même
/// quand il n'en a aucune. C'est l'unité qui reçoit stock et coût.
class _Target {
  final Product product;
  final ProductVariant? variant;
  const _Target(this.product, [this.variant]);

  String get key       => variant?.id ?? product.id!;
  String get label     => variant?.name ?? product.name;
  String? get sku      => variant?.sku ?? product.sku;
  int    get stock     => variant?.stockAvailable ?? product.stockQty;
  double get priceBuy  => variant?.priceBuy ?? product.priceBuy;
  /// Nom archivé sur le bon : le modèle seul ne suffirait pas à retrouver
  /// quelle déclinaison a été reçue.
  String get fullName =>
      variant == null ? product.name : '${product.name} — ${variant!.name}';
}

class _ArrivalSheet extends StatefulWidget {
  final String shopId;
  final ArrivalSheetMode initialMode;
  final Set<String>? preselectedIds;
  final bool lockMode;
  const _ArrivalSheet({
    required this.shopId,
    required this.initialMode,
    this.preselectedIds,
    this.lockMode = false,
  });

  @override
  State<_ArrivalSheet> createState() => _ArrivalSheetState();
}

class _ArrivalSheetState extends State<_ArrivalSheet> {
  late final List<Product> _catalogue;
  late bool _costOnly;
  late DateTime _date;
  bool _saving = false;
  String _query = '';

  /// key de [_Target] → quantité. En arrivage : ce qui entre. En frais
  /// seuls : les pièces qui se partagent les frais.
  final Map<String, int> _qty = {};
  final Map<String, TextEditingController> _costCtrls = {};
  final Map<String, _Target> _targets = {};
  final Set<String> _expanded = {};
  final List<FeeDraft> _fees = [];

  /// Produits pas encore au catalogue, saisis pendant l'arrivage. Ils ne sont
  /// créés en base qu'à la validation — annuler la feuille ne laisse aucune
  /// fiche orpheline derrière soi. Un même bon peut donc mélanger réassort
  /// (lignes `_qty`) et nouveautés (ces brouillons).
  final List<NewProductDraft> _drafts = [];

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _costOnly = widget.initialMode == ArrivalSheetMode.costOnly;
    _date     = DateTime.now();
    final all = AppDatabase.getProductsForShop(widget.shopId);
    final pre = widget.preselectedIds;
    _catalogue = pre == null
        ? all
        : all.where((p) => p.id != null && pre.contains(p.id)).toList();
    for (final p in _catalogue) {
      for (final t in _targetsOf(p)) {
        _targets[t.key] = t;
      }
    }
    // Sélection reçue de l'inventaire : les produits sont déjà choisis, on
    // charge chaque variante de son stock pour que la saisie se limite au
    // montant des frais. L'utilisateur peut ensuite décocher ce qui n'est
    // pas concerné.
    if (pre != null && _costOnly) {
      for (final t in _targets.values) {
        if (t.stock > 0) _qty[t.key] = t.stock;
      }
      _expanded.addAll(_catalogue
          .where((p) => _targetsOf(p).length > 1)
          .map((p) => p.id!));
    }
  }

  List<_Target> _targetsOf(Product p) => p.variants.isEmpty
      ? [_Target(p)]
      : p.variants.where((v) => v.id != null).map((v) => _Target(p, v)).toList();

  @override
  void dispose() {
    for (final c in _costCtrls.values) { c.dispose(); }
    for (final f in _fees) { f.dispose(); }
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Saisie d'un produit absent du catalogue. [name] amorce le nom quand la
  /// création part d'une recherche restée sans résultat — c'est le moment où
  /// l'on constate justement que le produit n'existe pas encore.
  Future<void> _addDraft({String? name}) async {
    final d = await showNewProductDraftSheet(context, initialName: name);
    if (d == null || !mounted) return;
    setState(() {
      _drafts.add(d);
      // La recherche qui n'a rien donné n'a plus lieu d'être : sans ce
      // nettoyage, le brouillon tout juste ajouté serait masqué par un
      // filtre qui ne correspond à rien.
      _query = '';
      _searchCtrl.clear();
    });
  }

  Future<void> _editDraft(NewProductDraft draft) async {
    final d = await showNewProductDraftSheet(context, initial: draft);
    if (d == null || !mounted) return;
    final i = _drafts.indexWhere((x) => x.key == draft.key);
    if (i < 0) return;
    setState(() => _drafts[i] = d);
  }

  /// Produits visibles + variantes retenues par la recherche. Chercher
  /// « bleu » doit remonter la variante, pas seulement le modèle.
  List<({Product product, List<_Target> targets})> get _visible {
    final q = _query.trim().toLowerCase();
    final out = <({Product product, List<_Target> targets})>[];
    for (final p in _catalogue) {
      final targets = _targetsOf(p);
      if (q.isEmpty) {
        out.add((product: p, targets: targets));
        continue;
      }
      final productHit = p.name.toLowerCase().contains(q) ||
          (p.sku ?? '').toLowerCase().contains(q);
      final hits = targets.where((t) =>
          t.label.toLowerCase().contains(q) ||
          (t.sku ?? '').toLowerCase().contains(q)).toList();
      if (productHit) {
        out.add((product: p, targets: targets));
      } else if (hits.isNotEmpty) {
        out.add((product: p, targets: hits));
      }
    }
    // Ce qui est déjà saisi remonte en tête : sur un long catalogue, la
    // saisie en cours doit rester sous les yeux.
    out.sort((a, b) {
      final sa = _targetsOf(a.product).any((t) => _qty.containsKey(t.key)) ? 0 : 1;
      final sb = _targetsOf(b.product).any((t) => _qty.containsKey(t.key)) ? 0 : 1;
      return sa != sb ? sa - sb : a.product.name.compareTo(b.product.name);
    });
    return out;
  }

  double _amount(String? raw) {
    if (raw == null) return 0;
    final v = double.tryParse(raw.trim().replaceAll(',', '.')) ?? 0;
    return v.isFinite && v > 0 ? v : 0;
  }

  double get _feesTotal =>
      _fees.fold(0.0, (s, f) => s + _amount(f.amount.text));

  /// Les brouillons comptent comme des lignes à part entière : leurs pièces
  /// participent à la répartition des frais du lot. Les en exclure ferait
  /// supporter tout le transport aux seuls produits déjà au catalogue.
  ArrivalCosting get _costing => ArrivalCostingService.compute(
    lines: [
      ..._qty.entries.map((e) => ArrivalLine(
        key:      e.key,
        quantity: e.value,
        unitCost: _costOnly ? 0 : _amount(_costCtrls[e.key]?.text),
      )),
      if (!_costOnly)
        ..._drafts.map((d) => ArrivalLine(
          key:      d.key,
          quantity: d.quantity,
          unitCost: d.priceBuy,
        )),
    ],
    feesTotal: _feesTotal,
  );

  bool get _canSubmit {
    if (_saving) return false;
    if (_qty.isEmpty && _drafts.isEmpty) return false;
    // Un bon de frais sans montant n'aurait aucun effet.
    if (_costOnly && _feesTotal <= 0) return false;
    return true;
  }

  /// Nombre de lignes que le bouton de validation annonce.
  int get _lineCount => _qty.length + (_costOnly ? 0 : _drafts.length);

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() => _saving = true);
    final user = LocalStorageService.getCurrentUser();
    final now  = DateTime.now();

    // Les fiches des nouveaux produits sont créées AVANT d'appliquer le bon :
    // `ArrivalService` relit le catalogue pour poser le stock, un produit
    // encore absent verrait sa ligne ignorée en silence.
    //
    // Elles naissent à stock 0 et prix d'achat 0 : c'est l'arrivage qui
    // entrera la quantité et posera le coût de revient (prix saisi + part de
    // frais du lot). Les pré-remplir doublerait le stock reçu.
    //
    // ⚠ AVEC une variante « Base », comme le fait la fiche produit. Un
    // produit sans variante ne reçoit AUCUN `StockLevel`
    // (`_syncShopStockLevelsFromProduct` n'itère que sur `p.variants`) : le
    // stock entrerait bien sur le produit, mais l'inventaire — qui lit le
    // StockLevel — afficherait 0 juste après l'arrivage.
    final createdIds = <String, String>{};
    final createdVariantIds = <String, String>{};
    if (!_costOnly) {
      final baseTs = now.microsecondsSinceEpoch;
      for (var i = 0; i < _drafts.length; i++) {
        final d  = _drafts[i];
        final id = 'prod_${baseTs + i}';
        final variantId = 'var_${baseTs + i}_0';
        try {
          await AppDatabase.saveProduct(
            Product(
              id:           id,
              storeId:      widget.shopId,
              name:         d.name,
              sku:          d.sku,
              priceBuy:     0,
              priceSellPos: d.priceSell,
              priceSellWeb: d.priceSell,
              stockQty:     0,
              isVisibleWeb: true,
              createdAt:    now,
              variants: [
                ProductVariant(
                  id:             variantId,
                  name:           'Base',
                  sku:            d.sku,
                  priceBuy:       0,
                  priceSellPos:   d.priceSell,
                  priceSellWeb:   d.priceSell,
                  stockAvailable: 0,
                  stockPhysical:  0,
                  isMain:         true,
                ),
              ],
            ),
            forceStockLevelSync: true,
          );
          createdIds[d.key]        = id;
          createdVariantIds[d.key] = variantId;
        } catch (e) {
          debugPrint('[Arrival] ⚠ création produit « ${d.name} » échouée : $e');
        }
      }
      // Une fiche non créée ne doit pas laisser croire que sa marchandise est
      // entrée : on interrompt plutôt que d'enregistrer un bon amputé.
      if (createdIds.length != _drafts.length) {
        if (!mounted) return;
        setState(() => _saving = false);
        AppSnack.error(context, 'Création d\'un nouveau produit impossible — '
            'arrivage non enregistré.');
        return;
      }
    }

    final items = <ReceptionItem>[
      ..._qty.entries.map((e) {
        final t = _targets[e.key]!;
        return ReceptionItem(
          id: 'ri_${now.microsecondsSinceEpoch}_${e.key}',
          productId:   t.product.id,
          // La variante EXACTE choisie — c'est elle qui reçoit stock et coût.
          variantId:   t.variant?.id,
          productName: t.fullName,
          expectedQty: e.value,
          receivedQty: e.value,
          unitCost: _costOnly ? 0 : _amount(_costCtrls[e.key]?.text),
        );
      }),
      if (!_costOnly)
        ..._drafts.map((d) => ReceptionItem(
          id: 'ri_${now.microsecondsSinceEpoch}_${d.key}',
          productId:   createdIds[d.key],
          // La variante « Base » tout juste créée : c'est elle qui portera
          // stock et coût de revient.
          variantId:   createdVariantIds[d.key],
          productName: d.name,
          expectedQty: d.quantity,
          receivedQty: d.quantity,
          unitCost:    d.priceBuy,
        )),
    ];

    final reception = Reception(
      id: 'rec_${now.millisecondsSinceEpoch}',
      shopId: widget.shopId,
      items: items,
      fees: _fees
          .map((f) => ReceptionFee(
              label: f.label.text.trim().isEmpty
                  ? 'Frais' : f.label.text.trim(),
              amount: _amount(f.amount.text)))
          .where((f) => f.amount > 0)
          .toList(),
      costOnly:  _costOnly,
      createdBy: user?.name,
      createdAt: _date,
    );

    await ArrivalService.apply(reception);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  bool _isToday(DateTime d) {
    final n = DateTime.now();
    return d.year == n.year && d.month == n.month && d.day == n.day;
  }

  /// Sélecteur de date de l'arrivage. Passé en `leading` à [LotFeesEditor]
  /// pour tenir sur la même ligne que l'en-tête des frais.
  Widget _datePicker() => InkWell(
    onTap: () async {
      final d = await pickBackDate(
          context: context, initial: _date,
          helpText: 'Date de l\'arrivage');
      if (d != null) setState(() => _date = d);
    },
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Row(children: [
        Icon(Icons.event_rounded, size: 14, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(
            _isToday(_date)
                ? 'Aujourd\'hui'
                : DateFormat('d MMMM yyyy', 'fr_FR').format(_date),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmBold)),
        Icon(Icons.edit_calendar_outlined, size: 12,
            color: AppColors.textHint),
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return DraggableScrollableSheet(
      // Ouverte au maximum : sur un écran peu haut (fenêtre de navigateur
      // ~580 px), les 3 % laissés en marge se prenaient directement sur la
      // liste de produits, déjà la partie la plus serrée de la feuille.
      initialChildSize: 0.95, minChildSize: 0.5, maxChildSize: 0.95,
      expand: false,
      builder: (_, sc) => Column(children: [
        Center(child: Container(width: 36, height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 12),
            decoration: BoxDecoration(color: sem.borderSubtle,
                borderRadius: BorderRadius.circular(2)))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Container(width: 34, height: 34,
                decoration: BoxDecoration(
                    color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(
                    _costOnly
                        ? Icons.receipt_long_rounded
                        : Icons.local_shipping_rounded,
                    size: 17, color: AppColors.primary)),
            const SizedBox(width: 10),
            Expanded(child: Text(
                _costOnly ? 'Frais sur stock existant' : 'Nouvel arrivage',
                style: AppTextStyles.subtitleBold)),
          ]),
        ),
        const SizedBox(height: 8),
        if (!widget.lockMode) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ArrivalModeSelector(
              costOnly: _costOnly,
              onChanged: (v) => setState(() {
                _costOnly = v;
                // Les quantités changent de sens d'un mode à l'autre : à
                // recevoir d'un côté, déjà en stock de l'autre.
                _qty.clear();
                // Créer un produit n'a aucun sens sur un bon de frais : le
                // stock y est déjà entré.
                _drafts.clear();
              }),
            ),
          ),
          const SizedBox(height: 6),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          // Date et « Frais du lot » PARTAGENT une ligne : deux réglages
          // ponctuels qui occupaient chacun toute la largeur, au détriment de
          // la liste de produits. Les frais saisis s'ouvrent en dessous, sur
          // toute la largeur.
          child: LotFeesEditor(
            fees: _fees,
            onChanged: () => setState(() {}),
            leading: _datePicker(),
          ),
        ),
        // Recherche et création de produit sur LA MÊME ligne : ajouter un
        // bouton pleine largeur aurait repris la hauteur qu'on vient de
        // rendre à la liste.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                style: AppTextStyles.input,
                decoration: InputDecoration(
                  hintText: 'Rechercher un produit ou une variante…',
                  hintStyle: AppTextStyles.bodySm
                      .copyWith(color: AppColors.textHint),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: AppColors.textHint),
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: sem.borderSubtle)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: sem.borderSubtle)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                          color: AppColors.primary, width: 1.5)),
                ),
              ),
            ),
            if (!_costOnly) ...[
              const SizedBox(width: 8),
              Tooltip(
                message: 'Produit absent du catalogue',
                child: InkWell(
                  onTap: () => _addDraft(),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    height: 40,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: AppColors.primarySurface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.5)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add_rounded,
                          size: 17, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text('Nouveau', style: AppTextStyles.bodySmBold
                          .copyWith(color: AppColors.primary)),
                    ]),
                  ),
                ),
              ),
            ],
          ]),
        ),
        Expanded(child: _buildList(sc)),
        LotSummary(costing: _costing, costOnly: _costOnly),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: SizedBox(width: double.infinity, height: 46,
            child: ElevatedButton.icon(
              onPressed: _canSubmit ? _submit : null,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded, size: 18),
              label: Text(_saving
                  ? 'Enregistrement…'
                  : _costOnly
                      ? 'Imputer les frais ($_lineCount)'
                      : 'Enregistrer l\'arrivage ($_lineCount)'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0, disabledBackgroundColor: AppColors.divider,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildList(ScrollController sc) {
    final groups = _visible;
    // Les nouveaux produits restent EN TÊTE, hors du tri et du filtre : ils
    // n'existent pas encore au catalogue, une recherche ne les retrouverait
    // pas, et c'est ce qu'on est en train de saisir.
    final drafts = _costOnly ? const <NewProductDraft>[] : _drafts;

    if (groups.isEmpty && drafts.isEmpty) {
      return ListView(
        controller: sc,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          const SizedBox(height: 24),
          Text('Aucun produit',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodySm
                  .copyWith(color: AppColors.textHint)),
          if (!_costOnly) ...[
            const SizedBox(height: 12),
            _createFromSearchCard(),
          ],
        ],
      );
    }

    // +1 pour l'invite de création quand la recherche ne remonte rien.
    final showCreate = !_costOnly && _query.trim().isNotEmpty && groups.isEmpty;
    return ListView.builder(
      controller: sc,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: drafts.length + groups.length + (showCreate ? 1 : 0),
      itemBuilder: (_, i) {
        if (i < drafts.length) {
          final d = drafts[i];
          return NewProductDraftCard(
            draft: d,
            onEdit:   () => _editDraft(d),
            onRemove: () => setState(() =>
                _drafts.removeWhere((x) => x.key == d.key)),
            onQuantity: (q) => setState(() => d.quantity = q),
          );
        }
        final j = i - drafts.length;
        if (j >= groups.length) return _createFromSearchCard();
        final g = groups[j];
        // Modèle sans déclinaison : une seule ligne, rien à déplier.
        if (g.targets.length == 1 && g.targets.first.variant == null) {
          return _targetRow(g.targets.first, standalone: true);
        }
        return _productGroup(g.product, g.targets);
      },
    );
  }

  /// Invite à créer le produit cherché — c'est en ne le trouvant pas qu'on
  /// réalise qu'il est nouveau, pas en cherchant un bouton dans l'en-tête.
  Widget _createFromSearchCard() {
    final q = _query.trim();
    return InkWell(
      onTap: () => _addDraft(name: q.isEmpty ? null : q),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.primarySurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.45)),
        ),
        child: Row(children: [
          Icon(Icons.add_box_rounded, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(
              q.isEmpty
                  ? 'Créer un nouveau produit'
                  : 'Créer « $q »',
              maxLines: 2, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmBold
                  .copyWith(color: AppColors.primary))),
          Icon(Icons.chevron_right_rounded,
              size: 18, color: AppColors.primary),
        ]),
      ),
    );
  }

  /// Modèle à variantes : en-tête repliable + une ligne par déclinaison.
  /// Sans ce repli, un catalogue de 50 modèles à 5 variantes afficherait
  /// 250 lignes d'un coup.
  Widget _productGroup(Product p, List<_Target> targets) {
    final sem  = Theme.of(context).semantic;
    final open = _expanded.contains(p.id);
    final picked = targets.where((t) => _qty.containsKey(t.key)).length;
    final totalQty = targets.fold<int>(
        0, (s, t) => s + (_qty[t.key] ?? 0));
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: picked > 0 ? AppColors.primarySurface : AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: picked > 0
            ? AppColors.primary.withValues(alpha: 0.3) : sem.borderSubtle)),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            if (open) { _expanded.remove(p.id); } else { _expanded.add(p.id!); }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, style: AppTextStyles.bodyBold,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                    picked > 0
                        ? '$picked variante${picked > 1 ? 's' : ''} · '
                          '$totalQty pièce${totalQty > 1 ? 's' : ''}'
                        : '${targets.length} variantes · '
                          'stock ${p.totalStock}',
                    style: AppTextStyles.micro.copyWith(
                        color: picked > 0
                            ? AppColors.primary : AppColors.textHint)),
              ])),
              Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  size: 20, color: AppColors.textSecondary),
            ]),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Column(
                children: targets.map((t) => _targetRow(t)).toList()),
          ),
      ]),
    );
  }

  /// Ligne saisissable — variante d'un modèle, ou produit sans déclinaison
  /// quand [standalone].
  Widget _targetRow(_Target t, {bool standalone = false}) {
    final sem = Theme.of(context).semantic;
    final qty = _qty[t.key] ?? 0;
    final inStock = t.stock;
    return Container(
      margin: EdgeInsets.only(bottom: standalone ? 6 : 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: standalone
            ? (qty > 0 ? AppColors.primarySurface : AppColors.surface)
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: qty > 0
            ? AppColors.primary.withValues(alpha: 0.3) : sem.borderSubtle)),
      child: Column(children: [
        Row(children: [
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(standalone ? t.product.name : t.label,
                style: standalone
                    ? AppTextStyles.bodyBold : AppTextStyles.bodySmBold,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(_costOnly ? '$inStock en stock' : 'Stock actuel : $inStock',
                style: AppTextStyles.micro.copyWith(color: AppColors.textHint)),
          ])),
          if (_costOnly)
            Switch(
              value: qty > 0,
              activeColor: AppColors.primary,
              onChanged: inStock <= 0 ? null : (on) => setState(() {
                if (on) { _qty[t.key] = inStock; } else { _qty.remove(t.key); }
              }),
            )
          else
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                onPressed: qty > 0 ? () => setState(() {
                  if (qty <= 1) { _qty.remove(t.key); }
                  else { _qty[t.key] = qty - 1; }
                }) : null,
                icon: const Icon(Icons.remove_circle_outline, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                color: AppColors.primary),
              SizedBox(width: 28, child: Center(child: Text('$qty',
                  style: AppTextStyles.label
                      .copyWith(fontWeight: FontWeight.w700)))),
              IconButton(
                onPressed: () => setState(() => _qty[t.key] = qty + 1),
                icon: const Icon(Icons.add_circle_outline, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                color: AppColors.primary),
            ]),
        ]),
        if (qty > 0 && !_costOnly) ...[
          const SizedBox(height: 8),
          MoneyField(
            label: 'Prix d\'achat unitaire',
            hint: 'Hors frais du lot',
            controller: _costCtrls.putIfAbsent(t.key, () =>
                TextEditingController(
                    text: t.priceBuy > 0
                        ? t.priceBuy.toStringAsFixed(0) : '')),
            onChanged: () => setState(() {}),
          ),
        ],
        if (qty > 0 && _costOnly) ...[
          const SizedBox(height: 8),
          PiecesStepper(
            value: qty,
            onChanged: (v) => setState(() {
              if (v <= 0) { _qty.remove(t.key); } else { _qty[t.key] = v; }
            }),
          ),
        ],
      ]),
    );
  }
}
