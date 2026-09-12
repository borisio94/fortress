import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/services/arrival_costing_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../domain/entities/product.dart';
import '../../domain/entities/reception.dart';
import '../../domain/entities/stock_movement.dart';
import '../widgets/arrival_widgets.dart';

/// Page de gestion des bons de réception.
/// Mode A : lié à une commande fournisseur (purchaseOrderId)
/// Mode B : réception directe (produits sélectionnés manuellement)
class ReceptionPage extends StatefulWidget {
  final String shopId;
  const ReceptionPage({super.key, required this.shopId});
  @override State<ReceptionPage> createState() => _ReceptionPageState();
}

class _ReceptionPageState extends State<ReceptionPage> {
  List<Reception> _receptions = [];

  @override
  void initState() {
    super.initState();
    _load();
    AppDatabase.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    if (table == 'receptions' || table == 'products') _load();
  }

  void _load() => setState(() {
    _receptions = HiveBoxes.receptionsBox.values
        .map((m) => Reception.fromMap(Map<String, dynamic>.from(m)))
        .where((r) => r.shopId == widget.shopId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  });

  @override
  Widget build(BuildContext context) {
    final drafts    = _receptions.where((r) => r.status == ReceptionStatus.draft).toList();
    final validated = _receptions.where((r) => r.status == ReceptionStatus.validated).toList();

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Historique des arrivages',
      isRootPage: false,
      body: _receptions.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.inbox_outlined, size: 48, color: AppColors.textHint),
              const SizedBox(height: 12),
              Text('Aucun arrivage enregistré',
                  style: AppTextStyles.labelRegular
                      .copyWith(color: AppColors.textHint)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                    "Les arrivages se saisissent depuis l'inventaire, "
                    'bouton camion à côté du « + ».',
                    textAlign: TextAlign.center,
                    style: AppTextStyles.micro
                        .copyWith(color: AppColors.textHint)),
              ),
            ]))
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (drafts.isNotEmpty) ...[
                _SectionLabel('Brouillons (${drafts.length})'),
                ...drafts.map((r) => _ReceptionCard(
                    reception: r, shopId: widget.shopId,
                    onValidate: () => _validate(r),
                    onDelete: () => _delete(r))),
                const SizedBox(height: 16),
              ],
              if (validated.isNotEmpty) ...[
                _SectionLabel('Validées (${validated.length})'),
                ...validated.map((r) => _ReceptionCard(
                    reception: r, shopId: widget.shopId)),
              ],
            ]),
    );
  }

  /// Frais saisis → entité, en écartant les lignes vides. Encore utilisé par
  /// la validation d'un brouillon (bon issu d'une commande fournisseur).
  static List<ReceptionFee> _feesOf(List<FeeDraft> fees) => fees
      .map((f) => ReceptionFee(
          label: f.label.text.trim().isEmpty
              ? 'Frais' : f.label.text.trim(),
          amount: _parseAmount(f.amount.text)))
      .where((f) => f.amount > 0)
      .toList();

  static double _parseAmount(String? raw) {
    if (raw == null) return 0;
    final v = double.tryParse(raw.trim().replaceAll(',', '.')) ?? 0;
    return v.isFinite && v > 0 ? v : 0;
  }

  /// Variante qui reçoit le stock (et donc le coût) : la principale, sinon
  /// la première. Même règle que `StockService._findVariant`.
  static String? _mainVariantId(Product p) {
    if (p.variants.isEmpty) return null;
    final main = p.variants.indexWhere((v) => v.isMain);
    return p.variants[main >= 0 ? main : 0].id;
  }

  // ── Valider une réception ──────────────────────────────────────────────
  void _validate(Reception reception) {
    // Ouvrir un dialog pour saisir les quantités reçues + incidents
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ValidateSheet(
        reception: reception,
        shopId: widget.shopId,
        onValidated: _load,
      ),
    );
  }

  Future<void> _delete(Reception r) async {
    final ref = r.id.length >= 6 ? r.id.substring(r.id.length - 6) : r.id;
    final confirmed = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer le bon de réception',
      description: 'Cette action est irréversible.',
      consequences: const [
        'Le bon disparaît définitivement de la liste.',
        'Les mouvements de stock déjà appliqués ne sont PAS annulés.',
      ],
      confirmText: ref,
      onConfirmed: () {},
    );
    if (confirmed != true || !mounted) return;
    await HiveBoxes.receptionsBox.delete(r.id);
    AppDatabase.bgDelete('receptions', val: r.id);
    _load();
    if (mounted) AppSnack.success(context, 'Bon supprimé');
  }
}

// ═══ Sheet de validation ════════════════════════════════════════════════════

class _ValidateSheet extends StatefulWidget {
  final Reception reception;
  final String shopId;
  final VoidCallback onValidated;
  const _ValidateSheet({required this.reception, required this.shopId,
    required this.onValidated});
  @override State<_ValidateSheet> createState() => _ValidateSheetState();
}

class _ValidateSheetState extends State<_ValidateSheet> {
  late List<_ItemState> _items;
  late List<FeeDraft>  _fees;

  @override
  void initState() {
    super.initState();
    _items = widget.reception.items.map((i) => _ItemState(
      item: i,
      receivedCtrl: TextEditingController(text: '${i.expectedQty}'),
      costCtrl: TextEditingController(
          text: i.unitCost > 0 ? i.unitCost.toStringAsFixed(0) : ''),
    )).toList();
    // Frais du lot repris du brouillon et encore modifiables : la facture
    // de transport n'est souvent connue qu'à l'arrivée de la marchandise.
    _fees = widget.reception.fees
        .map((f) => FeeDraft(label: f.label, amount: f.amount))
        .toList();
  }

  @override
  void dispose() {
    for (final i in _items) { i.dispose(); }
    for (final f in _fees)  { f.dispose(); }
    super.dispose();
  }

  bool get _costOnly => widget.reception.costOnly;

  /// Valorisation calculée sur les quantités RÉELLEMENT reçues.
  ArrivalCosting _costing() => ArrivalCostingService.compute(
    lines: _items.map((s) => ArrivalLine(
      key:      s.item.id,
      quantity: int.tryParse(s.receivedCtrl.text) ?? 0,
      unitCost: _ReceptionPageState._parseAmount(s.costCtrl.text),
    )).toList(),
    feesTotal: _fees.fold(
        0.0, (s, f) => s + _ReceptionPageState._parseAmount(f.amount.text)),
  );

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8, minChildSize: 0.5, maxChildSize: 0.95,
      expand: false,
      builder: (_, sc) => Column(children: [
        Center(child: Container(width: 36, height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 14),
            decoration: BoxDecoration(color: Theme.of(context).semantic.borderSubtle,
                borderRadius: BorderRadius.circular(2)))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Icon(_costOnly
                    ? Icons.receipt_long_rounded : Icons.fact_check_rounded,
                size: 20, color: const Color(0xFF3B82F6)),
            const SizedBox(width: 10),
            Expanded(child: Text(
                _costOnly
                    ? 'Imputation des frais'
                    : 'Validation de la réception',
                style: AppTextStyles.subtitleBold)),
          ]),
        ),
        const Divider(height: 24),
        Expanded(child: Builder(builder: (context) {
          final costing = _costing();
          return ListView.builder(
            controller: sc,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: _items.length + 1,
            itemBuilder: (_, i) {
              if (i == _items.length) {
                return LotFeesEditor(
                  fees: _fees, onChanged: () => setState(() {}));
              }
              final s = _items[i];
              final line = costing.lineFor(s.item.id);
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.item.productName, style: AppTextStyles.bodyBold),
                  Text(_costOnly
                          ? 'Pièces chargées : ${s.item.expectedQty}'
                          : 'Attendu : ${s.item.expectedQty}',
                      style: AppTextStyles.captionHint
                          .copyWith(color: AppColors.textHint)),
                  const SizedBox(height: 8),
                  _QtyField(
                      label: _costOnly
                          ? 'Pièces à charger' : 'Quantité reçue',
                      ctrl: s.receivedCtrl,
                      color: const Color(0xFF10B981)),
                  // Frais seuls : le prix d'achat n'est pas ressaisi — les
                  // frais s'ajoutent à celui déjà enregistré sur la fiche.
                  if (!_costOnly) ...[
                    const SizedBox(height: 8),
                    MoneyField(
                      label: 'Prix d\'achat unitaire',
                      hint: 'Hors frais du lot',
                      controller: s.costCtrl,
                      onChanged: () => setState(() {}),
                    ),
                  ],
                  if (_costOnly && costing.feePerPiece > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                        'Prix d\'achat : '
                        '+${CurrencyFormatter.format(costing.feePerPiece)} '
                        'par pièce',
                        style: AppTextStyles.micro
                            .copyWith(color: AppColors.primary)),
                  ] else if (line != null && line.landedUnitCost > 0) ...[
                    const SizedBox(height: 6),
                    Text(
                        'Coût de revient : '
                        '${CurrencyFormatter.format(line.landedUnitCost)} / pièce'
                        '${line.feePerPiece > 0
                            ? '  (dont ${CurrencyFormatter.format(line.feePerPiece)} de frais)'
                            : ''}',
                        style: AppTextStyles.micro
                            .copyWith(color: AppColors.primary)),
                  ],
                  const SizedBox(height: 4),
                  Text(
                      _costOnly
                          ? 'Aucune pièce n\'entre en stock : seul le prix '
                            'de revient est corrigé.'
                          : 'Les défauts se déclarent après en incident sur le produit.',
                      style: AppTextStyles.micro
                          .copyWith(color: AppColors.textHint)),
                ]),
              );
            },
          );
        })),
        LotSummary(costing: _costing(), costOnly: _costOnly),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: SizedBox(width: double.infinity, height: 46,
            child: ElevatedButton.icon(
              onPressed: _onValidate,
              icon: const Icon(Icons.check_circle_rounded, size: 18),
              label: Text(_costOnly
                  ? 'Imputer les frais' : 'Valider la réception'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            ),
          ),
        ),
      ]),
    );
  }

  Future<void> _onValidate() async {
    final now = DateTime.now();
    final user = LocalStorageService.getCurrentUser();
    final updatedItems = <ReceptionItem>[];

    // GF-6 — Plausibilité réceptions. Détecte les lignes saisies à
    // > 3× la moyenne historique (10 derniers entrées de la variante).
    // L'utilisateur doit confirmer explicitement avant l'écriture stock.
    // Log `reception_anormale` pour chaque ligne confirmée hors norme.
    final anomalies = <({_ItemState item, double avg, int qty})>[];
    // Un bon de frais seuls ne fait entrer aucune pièce : comparer ses
    // quantités à l'historique des réceptions n'aurait aucun sens (elles
    // décrivent du stock déjà là) et alerterait à tort.
    for (final s in _costOnly ? const <_ItemState>[] : _items) {
      final received = int.tryParse(s.receivedCtrl.text) ?? 0;
      if (received <= 0) continue;
      final vid = s.item.variantId;
      if (vid == null || vid.isEmpty) continue;
      final avg = StockService.avgReceptionQty(
        shopId: widget.shopId,
        variantId: vid,
      );
      if (avg > 0 && received > avg * 3) {
        anomalies.add((item: s, avg: avg, qty: received));
      }
    }
    if (anomalies.isNotEmpty) {
      final confirmed = await _showAnomalyConfirmDialog(anomalies);
      if (confirmed != true) return;
      // Trace les anomalies confirmées AVANT d'appliquer les écritures.
      for (final a in anomalies) {
        await ActivityLogService.log(
          action:      'reception_anormale',
          targetType:  'product',
          targetId:    a.item.item.productId ?? '',
          targetLabel: a.item.item.productName,
          shopId:      widget.shopId,
          details: {
            'variant_id':       a.item.item.variantId,
            'received_qty':     a.qty,
            'avg_historic':     a.avg,
            'ratio':            a.qty / a.avg,
            'reception_id':     widget.reception.id,
            'supervisor_id':    user?.id,
            'supervisor_name':  user?.name,
          },
        );
      }
    }

    // Répartition des frais du lot sur les quantités réellement reçues.
    final costing = _costing();

    for (final s in _items) {
      final received = int.tryParse(s.receivedCtrl.text) ?? 0;
      final line     = costing.lineFor(s.item.id);
      final landed   = line?.landedUnitCost ?? 0;

      updatedItems.add(s.item.copyWith(
        receivedQty: received,
        status: ReceptionItemStatus.available,
        unitCost: line?.unitCost ?? 0,
        landedUnitCost: landed,
      ));

      if (received > 0 && s.item.productId != null) {
        if (_costOnly) {
          // Frais seuls : AUCUNE entrée de stock. Le prix d'achat de la
          // variante augmente simplement de sa part de frais.
          await StockService.applyCostSurcharge(
            shopId:        widget.shopId,
            productId:     s.item.productId!,
            variantId:     s.item.variantId ?? '',
            feePerPiece:   costing.feePerPiece,
            piecesCharged: received,
            referenceId:   widget.reception.id,
          );
        } else {
          // Toute la quantité reçue entre en stock disponible, valorisée à
          // son coût de revient. Les défauts éventuels se déclarent ensuite
          // en incident.
          await _applyArrival(s.item.productId!, s.item.variantId, received,
              now, user?.name, landed);
        }
      }
    }

    // Mettre à jour la réception
    final validated = widget.reception.copyWith(
      status: ReceptionStatus.validated,
      items: updatedItems,
      fees: _ReceptionPageState._feesOf(_fees),
    );
    HiveBoxes.receptionsBox.put(validated.id, validated.toMap());
    AppDatabase.bgUpsert('receptions', validated.toMap());
    AppDatabase.notifyProductChange(widget.shopId);

    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onValidated();
    AppSnack.success(context, _costOnly
        ? 'Frais imputés — prix de revient mis à jour'
        : 'Réception validée — stock mis à jour');
  }

  Future<bool?> _showAnomalyConfirmDialog(
      List<({_ItemState item, double avg, int qty})> anomalies) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded,
              size: 20, color: AppColors.warning),
          SizedBox(width: 10),
          Expanded(child: Text('Quantité inhabituelle',
              style: AppTextStyles.subtitleBold)),
        ]),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Une ou plusieurs lignes dépassent 3× la moyenne historique '
                'de réception de cette variante. Vérifie les quantités '
                'saisies avant de valider.',
                style: AppTextStyles.bodySm,
              ),
              const SizedBox(height: 12),
              for (final a in anomalies) Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.item.item.productName,
                        style: AppTextStyles.bodyBold),
                    const SizedBox(height: 2),
                    Text(
                      'Saisi ${a.qty} · moyenne ${a.avg.toStringAsFixed(1)} · '
                      'ratio ${(a.qty / a.avg).toStringAsFixed(1)}×',
                      style: AppTextStyles.caption.copyWith(
                          color: AppColors.warning),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Corriger'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Valider quand même'),
          ),
        ],
      ),
    );
  }

  /// Entrée en stock d'une ligne d'arrivage, valorisée à [landedUnitCost]
  /// (0 = pas de prix saisi → seul le stock bouge, le coût reste intact).
  ///
  /// Passe par `StockService` plutôt que d'écrire le produit à la main :
  /// c'est lui qui tient `stockPhysical` en plus de `stockAvailable`, qui
  /// force la resynchro du `StockLevel` boutique (sans quoi l'inventaire
  /// affiche l'ancienne valeur) et qui trace le mouvement.
  Future<void> _applyArrival(String productId, String? variantId, int qty,
      DateTime now, String? userName, double landedUnitCost) async {
    final products = AppDatabase.getProductsForShop(widget.shopId);
    Product? product;
    for (final p in products) {
      if (p.id == productId) { product = p; break; }
    }

    if (product != null && product.variants.isNotEmpty) {
      final resolved = variantId != null &&
              product.variants.any((v) => v.id == variantId)
          ? variantId
          : _ReceptionPageState._mainVariantId(product);
      await StockService.arrivalAvailable(
        shopId: widget.shopId,
        productId: productId,
        variantId: resolved ?? '',
        quantity: qty,
        cause: 'supplier_delivery',
        referenceId: widget.reception.id,
        landedUnitCost: landedUnitCost > 0 ? landedUnitCost : null,
      );
      return;
    }

    // Produit sans variante : écriture directe + mouvement, comme avant.
    final mvt = StockMovement(
      id: 'sm_${now.microsecondsSinceEpoch}_$productId',
      shopId: widget.shopId, productId: productId,
      variantId: variantId, type: StockMovementType.entry,
      quantity: qty, createdBy: userName, createdAt: now,
    );
    HiveBoxes.stockMovementsBox.put(mvt.id, mvt.toMap());
    if (product == null) return;
    await AppDatabase.saveProduct(product.copyWith(
      stockQty: product.stockQty + qty,
      priceBuy: landedUnitCost > 0
          ? ArrivalCostingService.weightedAverageUnitCost(
              currentQty:       product.stockQty,
              currentUnitCost:  product.priceBuy,
              incomingQty:      qty,
              incomingUnitCost: landedUnitCost)
          : null,
    ));
  }

}

class _ItemState {
  final ReceptionItem item;
  final TextEditingController receivedCtrl;
  final TextEditingController costCtrl;
  _ItemState({required this.item, required this.receivedCtrl,
    required this.costCtrl});
  void dispose() { receivedCtrl.dispose(); costCtrl.dispose(); }
}
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: AppTextStyles.bodySmBold.copyWith(
        letterSpacing: 0.3, color: AppColors.textSecondary)),
  );
}

class _ReceptionCard extends StatelessWidget {
  final Reception reception;
  final String shopId;
  final VoidCallback? onValidate;
  final VoidCallback? onDelete;
  const _ReceptionCard({required this.reception, required this.shopId,
    this.onValidate, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final isDraft = reception.status == ReceptionStatus.draft;
    final statusColor = isDraft ? const Color(0xFFF59E0B) : const Color(0xFF10B981);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha:0.03),
            blurRadius: 4, offset: const Offset(0, 2))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: statusColor.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(6)),
            child: Text(reception.status.label,
                style: AppTextStyles.microBold
                    .copyWith(color: statusColor)),
          ),
          if (reception.costOnly) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(6)),
              child: Text('Frais seuls', style: AppTextStyles.microBold
                  .copyWith(color: AppColors.primary)),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(child: Text(
              '${reception.items.length} produit${reception.items.length > 1 ? 's' : ''}',
              style: AppTextStyles.bodySm
                  .copyWith(color: AppColors.textSecondary))),
          Text(_fmtDate(reception.createdAt),
              style: AppTextStyles.micro
                  .copyWith(color: AppColors.textHint)),
        ]),
        if (reception.hasCosting) ...[
          const SizedBox(height: 6),
          Row(children: [
            Icon(Icons.payments_rounded, size: 12, color: AppColors.textHint),
            const SizedBox(width: 5),
            Expanded(child: Text(
                reception.status == ReceptionStatus.validated
                    ? 'Coût du lot : '
                        '${CurrencyFormatter.format(reception.landedTotal)}'
                    : 'Frais du lot : '
                        '${CurrencyFormatter.format(reception.feesTotal)}',
                style: AppTextStyles.micro
                    .copyWith(color: AppColors.textSecondary))),
          ]),
        ],
        if (reception.status == ReceptionStatus.validated) ...[
          const SizedBox(height: 6),
          Row(children: [
            _Chip('Reçu: ${reception.totalReceived}', const Color(0xFF10B981)),
            if (reception.totalDamaged > 0) ...[
              const SizedBox(width: 6),
              _Chip('Endommagé: ${reception.totalDamaged}', const Color(0xFFF59E0B)),
            ],
            if (reception.totalDefective > 0) ...[
              const SizedBox(width: 6),
              _Chip('Défectueux: ${reception.totalDefective}', const Color(0xFFEF4444)),
            ],
          ]),
        ],
        if (isDraft) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Supprimer'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.error,
                side: BorderSide(color: AppColors.error.withValues(alpha:0.3)),
                padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            )),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton.icon(
              onPressed: onValidate,
              icon: const Icon(Icons.fact_check_rounded, size: 16),
              label: const Text('Valider'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF10B981), foregroundColor: Colors.white,
                elevation: 0, padding: const EdgeInsets.symmetric(vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            )),
          ]),
        ],
      ]),
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _Chip extends StatelessWidget {
  final String label; final Color color;
  const _Chip(this.label, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
        color: color.withValues(alpha:0.1), borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: AppTextStyles.micro
        .copyWith(fontWeight: FontWeight.w600, color: color)),
  );
}

class _QtyField extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final Color color;
  const _QtyField({required this.label, required this.ctrl, required this.color});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppTextStyles.micro
          .copyWith(fontWeight: FontWeight.w600, color: color)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: AppTextStyles.input
            .copyWith(fontWeight: FontWeight.w700, color: color),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          filled: true, fillColor: color.withValues(alpha:0.06),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: color.withValues(alpha:0.3))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: color.withValues(alpha:0.3))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: color, width: 1.5)),
        ),
      ),
    ],
  );
}
