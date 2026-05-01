import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_product_image.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../../../../features/inventaire/domain/entities/stock_transfer.dart';

/// Sheet de création d'un transfert instantané entre deux emplacements.
///
/// Flux :
/// 1. L'utilisateur choisit la source + la destination.
/// 2. Il ajoute une ou plusieurs lignes (variante + quantité) en tappant
///    sur un bouton qui ouvre un picker.
/// 3. Il valide → `StockService.executeTransfer` est appelé.
///
/// Retourne `true` via `Navigator.pop` si le transfert est exécuté, sinon
/// `false` (annulation) ou rien.
class TransferFormSheet extends StatefulWidget {
  final String ownerId;
  /// Source pré-sélectionnée (ex : ouvert depuis la page d'un emplacement).
  final String? presetSourceId;
  /// Produit pré-filtré : si fourni, le picker de variantes ne montre que
  /// les variantes de ce produit, et le picker s'ouvre automatiquement à
  /// l'arrivée pour raccourcir le flow (cas : tap "Transférer" sur la
  /// ligne produit dans l'inventaire).
  final String? presetProductId;
  const TransferFormSheet({
    super.key,
    required this.ownerId,
    this.presetSourceId,
    this.presetProductId,
  });

  @override
  State<TransferFormSheet> createState() => _TransferFormSheetState();
}

class _TransferFormSheetState extends State<TransferFormSheet> {
  List<StockLocation> _locations = [];
  String? _sourceId;
  String? _destId;
  final List<StockTransferLine> _lines = [];
  // variantId → URL image (variante prio, sinon produit). Sert à afficher
  // la vignette dans les lignes saisies (StockTransferLine n'a pas
  // d'imageUrl propre).
  final Map<String, String?> _imagesByVariantId = {};
  final _notesCtrl = TextEditingController();
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    // Filet défensif : on exclut les StockLocation type=shop dont la
    // boutique parente n'existe plus (locations orphelines suite à une
    // suppression incomplète — cascade Supabase ratée, race offline, etc.).
    // Cohérent avec le filtrage déjà appliqué dans stock_locations_page.
    _locations = AppDatabase.getStockLocationsForOwner(widget.ownerId)
        .where((l) => l.isActive)
        .where((l) => l.type != StockLocationType.shop
                   || (l.shopId != null
                       && LocalStorageService.getShop(l.shopId!) != null))
        .toList();
    _sourceId = widget.presetSourceId;
    for (final s in LocalStorageService.getShopsForUser(widget.ownerId)) {
      for (final p in AppDatabase.getProductsForShop(s.id)) {
        for (final v in p.variants) {
          if (v.id != null) {
            _imagesByVariantId[v.id!] = v.imageUrl ?? p.imageUrl;
          }
        }
      }
    }
    // Auto-ouverture du picker si un produit est pré-filtré : raccourci UX
    // depuis l'inventaire (tap "Transférer" sur la ligne produit).
    if (widget.presetProductId != null && _sourceId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _addLine();
      });
    }
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  StockLocation? get _source =>
      _locations.where((l) => l.id == _sourceId).firstOrNull;
  StockLocation? get _dest =>
      _locations.where((l) => l.id == _destId).firstOrNull;

  int _totalLines() => _lines.fold(0, (s, l) => s + l.quantity);

  Future<void> _addLine() async {
    final src = _source;
    if (src == null) {
      AppSnack.warning(context, 'Choisis d\'abord un emplacement source');
      return;
    }
    final excludedIds = _lines.map((l) => l.variantId).toSet();
    final picked = await showModalBottomSheet<StockTransferLine>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _VariantPickerSheet(
        source: src,
        excludedVariantIds: excludedIds,
        filterProductId: widget.presetProductId,
      ),
    );
    if (picked != null) {
      setState(() => _lines.add(picked));
    }
  }

  Future<void> _submit() async {
    final src = _source;
    final dst = _dest;
    if (src == null) {
      AppSnack.warning(context, 'Choisis la source'); return;
    }
    if (dst == null) {
      AppSnack.warning(context, 'Choisis la destination'); return;
    }
    if (src.id == dst.id) {
      AppSnack.warning(context, 'Source et destination doivent être différents');
      return;
    }
    if (_lines.isEmpty) {
      AppSnack.warning(context, 'Ajoute au moins une ligne au transfert');
      return;
    }
    final err = StockService.validateTransferLines(
        fromLoc: src, toLoc: dst, lines: _lines);
    if (err != null) {
      AppSnack.error(context, err);
      return;
    }

    setState(() => _submitting = true);
    try {
      final transfer = await StockService.executeTransfer(
        ownerId:         widget.ownerId,
        fromLocationId:  src.id,
        toLocationId:    dst.id,
        lines:           _lines,
        notes:           _notesCtrl.text.trim().isEmpty
                         ? null : _notesCtrl.text.trim(),
      );
      if (!mounted) return;
      if (transfer == null) {
        setState(() => _submitting = false);
        AppSnack.error(context,
            'Échec du transfert — vérifie les stocks et réessaie');
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.88),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Poignée
              Center(child: Container(width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 12),
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.swap_horiz_rounded,
                      size: 18, color: AppColors.primary),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Nouveau transfert',
                      style: TextStyle(fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A))),
                ),
              ]),
              const SizedBox(height: 16),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _Label('Source', required: true),
                      const SizedBox(height: 6),
                      _LocationDropdown(
                        locations: _locations,
                        value: _sourceId,
                        onChanged: (id) => setState(() {
                          _sourceId = id;
                          // Changer la source invalide les lignes saisies
                          _lines.clear();
                        }),
                      ),
                      const SizedBox(height: 12),

                      const _Label('Destination', required: true),
                      const SizedBox(height: 6),
                      _LocationDropdown(
                        locations: _locations,
                        value: _destId,
                        excludeId: _sourceId,
                        onChanged: (id) => setState(() => _destId = id),
                      ),
                      const SizedBox(height: 16),

                      Row(children: [
                        const _Label('Lignes', required: true),
                        const Spacer(),
                        if (_lines.isNotEmpty)
                          Text('${_lines.length} ligne${_lines.length > 1 ? 's' : ''} '
                              '· ${_totalLines()} unités',
                              style: const TextStyle(fontSize: 11,
                                  color: Color(0xFF9CA3AF))),
                      ]),
                      const SizedBox(height: 6),
                      if (_lines.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF9FAFB),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE5E7EB)),
                          ),
                          child: const Text(
                              'Aucune ligne. Clique "+ Ajouter une ligne" '
                              'ci-dessous pour sélectionner une variante à transférer.',
                              style: TextStyle(fontSize: 11,
                                  color: Color(0xFF6B7280))),
                        )
                      else
                        ..._lines.asMap().entries.map((e) => _LineTile(
                              line: e.value,
                              imageUrl:
                                  _imagesByVariantId[e.value.variantId],
                              onRemove: () => setState(() =>
                                  _lines.removeAt(e.key)),
                            )),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: _source == null ? null : _addLine,
                        icon: const Icon(Icons.add_rounded, size: 15),
                        label: const Text('Ajouter une ligne'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: BorderSide(
                              color: AppColors.primary.withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      const SizedBox(height: 14),

                      const _Label('Note (optionnel)'),
                      const SizedBox(height: 6),
                      TextField(
                        controller: _notesCtrl,
                        maxLines: 2,
                        style: const TextStyle(fontSize: 13),
                        decoration: _inputDecoration('Ex : livraison hebdomadaire'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: _submitting
                        ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Annuler'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.check_rounded, size: 16),
                    label: const Text('Valider le transfert'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

InputDecoration _inputDecoration(String hint) => InputDecoration(
  hintText: hint,
  hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
  filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
  contentPadding:
      const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
  border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
  enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
  focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
);

class _Label extends StatelessWidget {
  final String text;
  final bool required;
  const _Label(this.text, {this.required = false});
  @override
  Widget build(BuildContext context) => RichText(
    text: TextSpan(
      style: const TextStyle(fontSize: 11,
          fontWeight: FontWeight.w500, color: Color(0xFF6B7280)),
      children: [
        TextSpan(text: text),
        if (required) const TextSpan(text: ' *',
            style: TextStyle(color: Color(0xFFEF4444),
                fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

// ─── Dropdown d'emplacement ──────────────────────────────────────────────────
class _LocationDropdown extends StatelessWidget {
  final List<StockLocation> locations;
  final String? value;
  final String? excludeId;
  final ValueChanged<String?> onChanged;
  const _LocationDropdown({
    required this.locations,
    required this.value,
    required this.onChanged,
    this.excludeId,
  });

  static IconData _iconFor(StockLocationType t) => switch (t) {
    StockLocationType.shop      => Icons.storefront_rounded,
    StockLocationType.warehouse => Icons.warehouse_rounded,
    StockLocationType.partner   => Icons.local_shipping_rounded,
  };

  static Color _colorFor(StockLocationType t) => switch (t) {
    StockLocationType.shop      => AppColors.primary,
    StockLocationType.warehouse => AppColors.info,
    StockLocationType.partner   => AppColors.warning,
  };

  @override
  Widget build(BuildContext context) {
    final items = locations
        .where((l) => l.id != excludeId)
        .map((l) => DropdownMenuItem<String?>(
              value: l.id,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_iconFor(l.type), size: 14, color: _colorFor(l.type)),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 260),
                  child: Text(l.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13,
                          color: Color(0xFF0F172A))),
                ),
              ]),
            )).toList();

    return DropdownButtonFormField<String?>(
      value: locations.any((l) => l.id == value && l.id != excludeId)
          ? value : null,
      items: items,
      onChanged: onChanged,
      isDense: true,
      isExpanded: true,
      hint: const Text('Choisir…',
          style: TextStyle(fontSize: 13, color: Color(0xFFBBBBBB))),
      icon: const Icon(Icons.arrow_drop_down_rounded,
          color: Color(0xFF9CA3AF)),
      decoration: _inputDecoration(''),
    );
  }
}

// ─── Tuile d'une ligne déjà saisie ──────────────────────────────────────────
class _LineTile extends StatelessWidget {
  final StockTransferLine line;
  final String? imageUrl;
  final VoidCallback onRemove;
  const _LineTile({
    required this.line,
    required this.imageUrl,
    required this.onRemove,
  });
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFFF9FAFB),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    ),
    child: Row(children: [
      AppProductImage(
        imageUrl: imageUrl,
        width: 32, height: 32,
        borderRadius: BorderRadius.circular(6),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.productName ?? '—',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0F172A))),
            if ((line.variantName ?? '').isNotEmpty)
              Text(line.variantName!,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11,
                      color: Color(0xFF9CA3AF))),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.primary.withOpacity(0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('× ${line.quantity}',
            style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w700, color: AppColors.primary)),
      ),
      IconButton(
        icon: const Icon(Icons.close_rounded, size: 16,
            color: Color(0xFF9CA3AF)),
        onPressed: onRemove,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        tooltip: 'Retirer cette ligne',
      ),
    ]),
  );
}

// ─── Sheet de sélection d'une variante + saisie quantité ────────────────────
class _VariantPickerSheet extends StatefulWidget {
  final StockLocation source;
  final Set<String> excludedVariantIds;
  /// Si non null, n'affiche que les variantes de ce produit (filtre par
  /// productId — utilisé pour le raccourci "Transférer" depuis la ligne
  /// produit de l'inventaire).
  final String? filterProductId;
  const _VariantPickerSheet({
    required this.source,
    required this.excludedVariantIds,
    this.filterProductId,
  });

  @override
  State<_VariantPickerSheet> createState() => _VariantPickerSheetState();
}

class _VariantPickerSheetState extends State<_VariantPickerSheet> {
  String _query = '';
  _VariantEntry? _selected;
  final _qtyCtrl = TextEditingController(text: '1');

  late List<_VariantEntry> _all;

  @override
  void initState() {
    super.initState();
    _all = _loadVariantsAtSource();
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  List<_VariantEntry> _loadVariantsAtSource() {
    final out = <_VariantEntry>[];
    final filterPid = widget.filterProductId;
    if (widget.source.type == StockLocationType.shop
        && widget.source.shopId != null) {
      for (final p in AppDatabase.getProductsForShop(widget.source.shopId!)) {
        if (filterPid != null && p.id != filterPid) continue;
        for (final v in p.variants) {
          if (v.id == null || v.id!.isEmpty) continue;
          if (widget.excludedVariantIds.contains(v.id)) continue;
          if (v.stockAvailable <= 0) continue;
          out.add(_VariantEntry(
            product: p, variant: v, available: v.stockAvailable));
        }
      }
    } else {
      // Warehouse/partner : se baser sur les StockLevel
      final levels = AppDatabase.getStockLevelsForLocation(widget.source.id)
          .where((l) => l.stockAvailable > 0
                     && !widget.excludedVariantIds.contains(l.variantId))
          .toList();
      // Indexer les produits du owner pour lookup
      final userId = LocalStorageService.getCurrentUser()?.id ?? '';
      final byVid = <String, _VariantEntry>{};
      for (final s in LocalStorageService.getShopsForUser(userId)) {
        for (final p in AppDatabase.getProductsForShop(s.id)) {
          for (final v in p.variants) {
            if (v.id != null && v.id!.isNotEmpty) {
              byVid[v.id!] = _VariantEntry(
                  product: p, variant: v, available: 0);
            }
          }
        }
      }
      for (final lvl in levels) {
        final e = byVid[lvl.variantId];
        if (e != null) {
          if (filterPid != null && e.product.id != filterPid) continue;
          out.add(_VariantEntry(
              product: e.product,
              variant: e.variant,
              available: lvl.stockAvailable));
        }
      }
    }
    out.sort((a, b) =>
        a.product.name.toLowerCase().compareTo(b.product.name.toLowerCase()));
    return out;
  }

  List<_VariantEntry> get _filtered {
    if (_query.trim().isEmpty) return _all;
    final q = _query.trim().toLowerCase();
    return _all.where((e) =>
      e.product.name.toLowerCase().contains(q) ||
      e.variant.name.toLowerCase().contains(q) ||
      (e.variant.sku ?? '').toLowerCase().contains(q)
    ).toList();
  }

  void _confirm() {
    final entry = _selected;
    if (entry == null) return;
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    if (qty <= 0) {
      AppSnack.warning(context, 'Quantité invalide');
      return;
    }
    if (qty > entry.available) {
      AppSnack.warning(context,
          'Max disponible : ${entry.available}');
      return;
    }
    Navigator.of(context).pop(StockTransferLine(
      variantId:   entry.variant.id!,
      quantity:    qty,
      productName: entry.product.name,
      variantName: entry.variant.name,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.80),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(child: Container(width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 10),
              const Text('Ajouter une variante',
                  style: TextStyle(fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A))),
              const SizedBox(height: 10),
              TextField(
                onChanged: (v) => setState(() => _query = v),
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: _inputDecoration(
                    'Rechercher un produit, variante ou SKU…')
                    .copyWith(prefixIcon: const Icon(
                        Icons.search_rounded, size: 18,
                        color: Color(0xFF9CA3AF))),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: Text(
                              'Aucune variante disponible à la source',
                              style: TextStyle(fontSize: 12,
                                  color: Color(0xFF9CA3AF))),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: list.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, color: Color(0xFFF0F0F0)),
                        itemBuilder: (_, i) {
                          final e = list[i];
                          final selected = _selected?.variant.id == e.variant.id;
                          return InkWell(
                            onTap: () => setState(() {
                              _selected = e;
                              _qtyCtrl.text = '1';
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 10),
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppColors.primary.withOpacity(0.08)
                                    : null,
                              ),
                              child: Row(children: [
                                Icon(
                                    selected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_off_rounded,
                                    size: 15,
                                    color: selected
                                        ? AppColors.primary
                                        : const Color(0xFFBBBBBB)),
                                const SizedBox(width: 10),
                                AppProductImage(
                                  imageUrl: e.variant.imageUrl
                                      ?? e.product.imageUrl,
                                  width: 32, height: 32,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(e.product.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF0F172A))),
                                      if (e.variant.name.isNotEmpty)
                                        Text(e.variant.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF9CA3AF))),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text('${e.available} dispo',
                                    style: const TextStyle(fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF10B981))),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              if (_selected != null)
                _QtySelector(
                  controller: _qtyCtrl,
                  max: _selected!.available,
                  onConfirm: _confirm,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VariantEntry {
  final Product product;
  final ProductVariant variant;
  final int available;
  _VariantEntry({
    required this.product, required this.variant, required this.available,
  });
}

// ─── Sélecteur de quantité (isolé) ───────────────────────────────────────────
// Widget dédié qui évite les Spacers dans les Rows conditionnelles — c'est
// ce qui déclenchait "Cannot hit test a render box with no size" lors de
// l'apparition de ce bloc par setState.
class _QtySelector extends StatelessWidget {
  final TextEditingController controller;
  final int max;
  final VoidCallback onConfirm;
  const _QtySelector({
    required this.controller,
    required this.max,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('Quantité',
                style: TextStyle(fontSize: 11,
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w500)),
            Text('Max : $max',
                style: const TextStyle(fontSize: 11,
                    color: Color(0xFF9CA3AF))),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            SizedBox(
              width: 100,
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(fontSize: 13),
                decoration: _inputDecoration('1'),
              ),
            ),
            SizedBox(
              width: 140,
              child: ElevatedButton(
                onPressed: onConfirm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Ajouter'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
