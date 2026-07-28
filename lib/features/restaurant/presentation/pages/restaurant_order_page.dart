import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../features/caisse/domain/entities/sale_item.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/menu_modifier.dart';
import '../../domain/entities/restaurant_table.dart';
import '../widgets/menu_item_tile.dart';
import '../widgets/modifier_picker_sheet.dart';
import '../widgets/order_recap_panel.dart';
import '../../../../core/services/kitchen_ticket_printer.dart';

/// Prise de commande pour une table (module restaurant, PR-2).
///
/// UI entièrement dédiée au service en salle — elle ne réutilise NI
/// `CaissePage`, NI `CartWidget`, NI `product_grid_widget.dart` : l'ergonomie
/// d'un serveur en salle (tap rapide, options par plat, envoi cuisine) n'a
/// rien à voir avec celle d'une caisse e-commerce. Seule la couche données
/// est mutualisée, via [RestaurantOrderService].
class RestaurantOrderPage extends StatefulWidget {
  final String shopId;
  final String tableId;

  const RestaurantOrderPage({
    super.key,
    required this.shopId,
    required this.tableId,
  });

  @override
  State<RestaurantOrderPage> createState() => _RestaurantOrderPageState();
}

class _RestaurantOrderPageState extends State<RestaurantOrderPage> {
  RestaurantTable? _table;
  Sale? _existingOrder;

  /// Lignes en cours d'édition. Copie locale : rien n'est persisté tant que
  /// le serveur n'a pas validé (« Envoyer en cuisine » ou « Enregistrer »),
  /// pour qu'un aller-retour dans le menu ne génère pas 15 écritures.
  final List<SaleItem> _lines = [];

  int _covers = 1;
  String? _category;
  bool _saving = false;

  /// True dès qu'une modification locale n'a pas encore été persistée.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final table = RestaurantTableService.tableById(widget.tableId);
    if (table == null) return;
    // Tournée EN ATTENTE et non « première commande de la table » : les
    // tournées déjà envoyées sont figées, leur bon est parti en cuisine. En
    // rouvrir une reviendrait à réécrire un bon déjà imprimé.
    final order = RestaurantOrderService.pendingRoundFor(table);
    setState(() {
      _table = table;
      _existingOrder = order;
      _covers = (order?.covers ?? table.covers ?? 1)
          .clamp(1, table.capacity);
      _lines
        ..clear()
        ..addAll(order?.items ?? const []);
      _dirty = false;
    });
  }

  List<Product> get _products =>
      LocalStorageService.getProductsForShop(widget.shopId);

  List<String> get _categories {
    // Catégories réellement portées par au moins un produit — la liste
    // brute de la boutique contiendrait des catégories vides, inutiles
    // en service et coûteuses en place sur la barre d'onglets.
    final used = <String>{};
    for (final p in _products) {
      final c = p.categoryId;
      if (c != null && c.isNotEmpty) used.add(c);
    }
    final list = used.toList()..sort();
    return list;
  }

  List<Product> get _visibleProducts {
    final all = _products;
    if (_category == null) return all;
    return all.where((p) => p.categoryId == _category).toList();
  }

  double get _total =>
      _lines.fold(0.0, (sum, i) => sum + i.subtotal);

  // ── Actions ─────────────────────────────────────────────────────────────

  /// Ajout simple : pas d'options, on incrémente la ligne existante.
  void _addProduct(Product p, {List<Map<String, dynamic>> modifiers = const []}) {
    // `Product.id` est nullable (produit jamais persisté). Un tel produit ne
    // peut pas être commandé : sans id, la ligne serait impossible à relier
    // au stock et à la fiche produit.
    final pid = p.id;
    if (pid == null || pid.isEmpty) {
      AppSnack.error(context, 'Article non enregistré : ${p.name}');
      return;
    }
    final item = RestaurantOrderService.buildItem(
      productId: pid,
      productName: p.name,
      unitPrice: p.priceSellPos,
      priceBuy: p.priceBuy,
      imageUrl: p.imageUrl,
      modifiers: modifiers,
    );
    setState(() {
      // Fusion sur (produit + options) : un steak saignant et un steak bien
      // cuit sont deux lignes distinctes, deux steaks saignants n'en font
      // qu'une en quantité 2.
      final idx = _lines.indexWhere((l) =>
          l.productId == item.productId &&
          l.modifiersKey == item.modifiersKey);
      if (idx >= 0) {
        _lines[idx] = _lines[idx].copyWith(quantity: _lines[idx].quantity + 1);
      } else {
        _lines.add(item);
      }
      _dirty = true;
    });
  }

  Future<void> _openModifiers(Product p) async {
    final pid = p.id;
    if (pid == null || pid.isEmpty) return;
    final groups = RestaurantOrderService.modifiersFor(widget.shopId, pid);
    if (groups.isEmpty) {
      AppSnack.info(context,
          'Aucune option configurée pour ${p.name}.');
      return;
    }
    final chosen = await showModifierPicker(
      context: context,
      productName: p.name,
      basePrice: p.priceSellPos,
      groups: groups,
    );
    if (chosen == null || !mounted) return;
    _addProduct(p, modifiers: chosen);
  }

  void _changeQuantity(int index, int delta) {
    setState(() {
      final line = _lines[index];
      final q = line.quantity + delta;
      if (q <= 0) {
        _lines.removeAt(index);
      } else {
        _lines[index] = line.copyWith(quantity: q);
      }
      _dirty = true;
    });
  }

  /// Persiste la commande. [thenSendToKitchen] enchaîne l'envoi en cuisine.
  Future<void> _save({bool thenSendToKitchen = false}) async {
    final table = _table;
    if (table == null) return;
    if (_lines.isEmpty) {
      AppSnack.error(context, 'Ajoutez au moins un article.');
      return;
    }
    setState(() => _saving = true);
    try {
      final order = await RestaurantOrderService.saveTableOrder(
        table: table,
        items: List.of(_lines),
        covers: _covers,
        existing: _existingOrder,
      );
      if (thenSendToKitchen) {
        // Numéro calculé AVANT l'envoi : une fois la tournée figée, elle
        // compte dans le total et le numéro serait décalé d'une unité.
        final round = RestaurantOrderService.roundNumberFor(
            table, tabLabel: order.tabLabel);
        await RestaurantOrderService.sendRound(order);
        if (!mounted) return;
        // Le bon part à l'impression : c'est le seul canal vers la cuisine,
        // personne n'a d'écran là-bas.
        await KitchenTicketPrinter.print(
          context: context,
          shopId: widget.shopId,
          order: order,
          tableName: table.name,
          round: round,
        );
      }
      if (!mounted) return;
      AppSnack.success(
          context,
          thenSendToKitchen
              ? 'Tournée envoyée en cuisine'
              : 'Commande enregistrée');
      // Rechargement : après un envoi, `pendingRoundFor` ne trouve plus rien
      // et l'écran repart sur une tournée vide — prêt pour l'apéritif que le
      // client demandera pendant la préparation.
      _load();
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Ouvre l'addition. Bascule d'abord la table en statut `addition` pour
  /// que le plan de salle reflète immédiatement la demande du client.
  Future<void> _openBill() async {
    final table = _table;
    if (table == null) return;
    if (_dirty && !await _confirmLeave()) return;
    if (table.status != RestaurantTableStatus.addition) {
      await RestaurantTableService.requestBill(table);
    }
    if (!mounted) return;
    context.push('/shop/${widget.shopId}/restaurant/addition/${table.id}');
  }

  /// Confirme la sortie quand des lignes ne sont pas persistées.
  Future<bool> _confirmLeave() async {
    if (!_dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitter sans enregistrer ?'),
        content: const Text(
            'Les articles ajoutés depuis le dernier enregistrement '
            'seront perdus.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Rester')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Quitter')),
        ],
      ),
    );
    return leave ?? false;
  }

  // ── Rendu ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final table = _table;
    if (table == null) {
      return AppScaffold(
        shopId: widget.shopId,
        title: 'Commande',
        isRootPage: false,
        body: const Center(child: Text('Table introuvable.')),
      );
    }

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && mounted) {
          if (context.mounted) context.pop();
        }
      },
      child: AppScaffold(
        shopId: widget.shopId,
        title: table.name,
        isRootPage: false,
        actions: [
          // Raccourci vers l'addition (spec §7). Désactivé tant que rien
          // n'est persisté : additionner un panier non enregistré donnerait
          // un total faux.
          IconButton(
            tooltip: 'Addition',
            onPressed: _existingOrder == null ? null : _openBill,
            icon: const Icon(Icons.receipt_long_rounded),
          ),
        ],
        body: Column(
          children: [
            _OpeningBanner(label: _openedLabel(table)),
            _CoversSelector(
              covers: _covers,
              capacity: table.capacity,
              onChanged: (v) => setState(() {
                _covers = v;
                _dirty = true;
              }),
            ),
            _CategoryTabs(
              categories: _categories,
              selected: _category,
              onSelect: (c) => setState(() => _category = c),
            ),
            Expanded(child: _buildMenuGrid()),
            OrderRecapPanel(
              lines: _lines,
              total: _total,
              saving: _saving,
              alreadySent: _existingOrder?.sentToKitchen ?? false,
              onChangeQuantity: _changeQuantity,
              onSave: () => _save(),
              onSendToKitchen: () => _save(thenSendToKitchen: true),
            ),
          ],
        ),
      ),
    );
  }

  String _openedLabel(RestaurantTable t) {
    final opened = t.openedAt;
    final covers = '$_covers couvert${_covers > 1 ? 's' : ''}';
    if (opened == null) return covers;
    final hh = opened.hour.toString().padLeft(2, '0');
    final mm = opened.minute.toString().padLeft(2, '0');
    return 'Ouverte à $hh:$mm · $covers';
  }

  Widget _buildMenuGrid() {
    final products = _visibleProducts;
    if (products.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _category == null
                ? 'Aucun article au menu. Ajoutez vos plats depuis '
                    'l\'inventaire.'
                : 'Aucun article dans « $_category ».',
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySecondary,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 2 colonnes en mobile (spec), plus au-delà pour ne pas étirer les
        // cartes sur une tablette de salle posée en paysage.
        final columns = (constraints.maxWidth / 190).floor().clamp(2, 6);
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.45,
          ),
          itemCount: products.length,
          itemBuilder: (_, i) {
            final p = products[i];
            return MenuItemTile(
              name: p.name,
              price: p.priceSellPos,
              imageUrl: p.mainImageUrl,
              hasModifiers: RestaurantOrderService
                  .modifiersFor(widget.shopId, p.id ?? '')
                  .isNotEmpty,
              onAdd: () => _addProduct(p),
              onLongPress: () => _openModifiers(p),
            );
          },
        );
      },
    );
  }
}

/// Sélecteur de couverts (+/−) affiché en tête de la prise de commande.
class _CoversSelector extends StatelessWidget {
  final int covers;
  final int capacity;
  final ValueChanged<int> onChanged;

  const _CoversSelector({
    required this.covers,
    required this.capacity,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.semantic.trackMuted,
      child: Row(
        children: [
          Icon(Icons.people_rounded,
              size: 18, color: theme.colorScheme.onSurface),
          const SizedBox(width: 8),
          const Text('Couverts', style: AppTextStyles.bodySmBold),
          const Spacer(),
          IconButton(
            onPressed: covers > 1 ? () => onChanged(covers - 1) : null,
            icon: const Icon(Icons.remove_circle_outline_rounded),
          ),
          Text('$covers', style: AppTextStyles.subtitleBold),
          IconButton(
            // Plafonné à la CAPACITÉ de la table. L'ancienne tolérance de
            // +6 laissait asseoir 10 personnes à une table de 4 : le plan de
            // salle annonçait alors une occupation que la salle ne pouvait
            // pas tenir. Pour un groupe plus grand, on ajoute une table.
            onPressed: covers < capacity ? () => onChanged(covers + 1) : null,
            icon: const Icon(Icons.add_circle_outline_rounded),
          ),
        ],
      ),
    );
  }
}

/// Onglets de catégories, défilables horizontalement.
class _CategoryTabs extends StatelessWidget {
  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelect;

  const _CategoryTabs({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          _chip(context, label: 'Tout', value: null),
          for (final c in categories) _chip(context, label: c, value: c),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required String? value}) {
    final isSel = selected == value;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: isSel,
        onSelected: (_) => onSelect(value),
        labelStyle: AppTextStyles.bodySm.copyWith(
          color: isSel ? theme.colorScheme.primary : null,
          fontWeight: isSel ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}

/// Ouvre la feuille de choix des options d'un plat.
Future<List<Map<String, dynamic>>?> showModifierPicker({
  required BuildContext context,
  required String productName,
  required double basePrice,
  required List<MenuModifier> groups,
}) =>
    showModalBottomSheet<List<Map<String, dynamic>>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => ModifierPickerSheet(
        productName: productName,
        basePrice: basePrice,
        groups: groups,
      ),
    );

/// Bandeau d'en-tête : heure d'ouverture du service et couverts.
class _OpeningBanner extends StatelessWidget {
  final String label;
  const _OpeningBanner({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: theme.colorScheme.primary.withValues(alpha: 0.08),
      child: Text(label,
          style: AppTextStyles.caption
              .copyWith(color: theme.colorScheme.primary)),
    );
  }
}
