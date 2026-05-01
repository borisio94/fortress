import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../domain/entities/incident.dart';
import '../../domain/entities/product.dart';
import '../../../../core/services/stock_service.dart';

class IncidentsPage extends StatefulWidget {
  final String shopId;
  const IncidentsPage({super.key, required this.shopId});
  @override State<IncidentsPage> createState() => _IncidentsPageState();
}

class _IncidentsPageState extends State<IncidentsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<Incident> _incidents = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() => setState(() {}));
    _load();
    AppDatabase.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDbChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onDbChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    if (table == 'incidents') _load();
  }

  void _load() => setState(() {
    _incidents = HiveBoxes.incidentsBox.values
        .map((m) => Incident.fromMap(Map<String, dynamic>.from(m)))
        .where((i) => i.shopId == widget.shopId)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  });

  List<Incident> get _pending  => _incidents.where((i) => i.isPending).toList();
  List<Incident> get _active   => _incidents.where((i) =>
      i.status == IncidentStatus.inProgress).toList();
  List<Incident> get _resolved => _incidents.where((i) =>
      i.isResolved || i.status == IncidentStatus.cancelled).toList();

  @override
  Widget build(BuildContext context) {
    final pendingCount = _pending.length;
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Zone Incidents',
      isRootPage: false,
      body: Column(children: [
        // Résumé
        if (_incidents.isNotEmpty)
          _SummaryBar(
            pending:  pendingCount,
            active:   _active.length,
            resolved: _resolved.length,
            totalCost: _incidents
                .where((i) => i.isResolved)
                .fold(0.0, (s, i) => s + i.repairCost),
          ),
        // Tabs
        Container(
          color: Colors.white,
          child: TabBar(
            controller: _tab,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.textHint,
            indicatorColor: AppColors.primary,
            indicatorWeight: 2,
            labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            tabs: [
              Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('En attente'),
                if (pendingCount > 0) ...[
                  const SizedBox(width: 6),
                  _Badge(pendingCount, AppColors.error),
                ],
              ])),
              Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('En cours'),
                if (_active.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _Badge(_active.length, AppColors.info),
                ],
              ])),
              const Tab(text: 'Résolus'),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        // Contenu
        Expanded(child: TabBarView(controller: _tab, children: [
          _IncidentList(incidents: _pending, onAction: _showResolveSheet,
              onDelete: _confirmDeleteIncident),
          _IncidentList(incidents: _active, onAction: _showResolveSheet,
              onDelete: _confirmDeleteIncident),
          _IncidentList(incidents: _resolved),
        ])),
      ]),
    );
  }

  Future<void> _confirmDeleteIncident(Incident incident) async {
    final ok = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer l\'incident',
      description: '${incident.productName} · ×${incident.quantity} · '
          '${incident.type.label}',
      consequences: const [
        'L\'incident sort de la liste de suivi.',
        'Si non résolu, le stock bloqué sera remis en disponible.',
      ],
      confirmText: incident.productName,
      onConfirmed: () {},
    );
    if (ok != true || !mounted) return;
    _deleteIncident(incident);
  }

  void _deleteIncident(Incident incident) async {
    final pid = incident.productId ?? '';
    final vid = incident.variantId ?? pid;

    // Si l'incident n'est pas encore résolu, le stock est encore en "blocked".
    // Le ramener en disponible avant de supprimer l'enregistrement.
    if ((incident.isPending || incident.status == IncidentStatus.inProgress)
        && pid.isNotEmpty) {
      await StockService.incidentToAvailable(
        shopId: widget.shopId, productId: pid, variantId: vid,
        quantity: incident.quantity, resolution: 'cancelled',
        incidentId: incident.id);
    }

    // Supprimer d'éventuelles arrivées legacy liées à cet incident
    // (avant la réforme, un incident sur stock existant créait aussi une
    // arrivée 'damaged'/'defective' dans stockArrivalsBox).
    final arrivalKeys = HiveBoxes.stockArrivalsBox.keys.where((k) {
      final m = HiveBoxes.stockArrivalsBox.get(k);
      if (m is! Map) return false;
      return m['product_id'] == pid
          && m['quantity'] == incident.quantity
          && m['status'] != 'available'
          && m['created_at'] == incident.createdAt.toIso8601String();
    }).toList();
    for (final k in arrivalKeys) HiveBoxes.stockArrivalsBox.delete(k);

    HiveBoxes.incidentsBox.delete(incident.id);

    AppDatabase.notifyProductChange(widget.shopId);
    _load();
    if (mounted) AppSnack.success(context, 'Incident supprimé');
  }

  void _showResolveSheet(Incident incident) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _ResolveSheet(
        incident: incident,
        shopId: widget.shopId,
        onResolved: _load,
      ),
    );
  }
}

// ═══ Barre résumé ═══════════════════════════════════════════════════════════

class _SummaryBar extends StatelessWidget {
  final int pending, active, resolved;
  final double totalCost;
  const _SummaryBar({required this.pending, required this.active,
    required this.resolved, required this.totalCost});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white, borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.divider),
    ),
    child: Row(children: [
      _Kpi('En attente', '$pending', AppColors.error),
      _div(),
      _Kpi('En cours', '$active', AppColors.info),
      _div(),
      _Kpi('Résolus', '$resolved', AppColors.secondary),
      if (totalCost > 0) ...[
        _div(),
        _Kpi('Coût répar.', CurrencyFormatter.format(totalCost), AppColors.warning),
      ],
    ]),
  );

  Widget _div() => Container(width: 1, height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: AppColors.divider);
}

class _Kpi extends StatelessWidget {
  final String label, value; final Color color;
  const _Kpi(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) => Expanded(child: Column(children: [
    Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color)),
    Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textHint)),
  ]));
}

class _Badge extends StatelessWidget {
  final int count; final Color color;
  const _Badge(this.count, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
    child: Text('$count', style: const TextStyle(fontSize: 9,
        fontWeight: FontWeight.w700, color: Colors.white)),
  );
}

// ═══ Liste d'incidents ══════════════════════════════════════════════════════

class _IncidentList extends StatelessWidget {
  final List<Incident> incidents;
  final void Function(Incident)? onAction;
  final void Function(Incident)? onDelete;
  const _IncidentList({required this.incidents, this.onAction, this.onDelete});

  @override
  Widget build(BuildContext context) {
    if (incidents.isEmpty) {
      return const EmptyStateWidget(
        icon: Icons.check_circle_outline_rounded,
        title: 'Aucun incident',
        subtitle: 'Tout est en ordre',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: incidents.length,
      itemBuilder: (_, i) => _IncidentCard(
        incident: incidents[i],
        onAction: onAction != null ? () => onAction!(incidents[i]) : null,
        onDelete: onDelete != null ? () => onDelete!(incidents[i]) : null,
      ),
    );
  }
}

// ═══ Card incident ══════════════════════════════════════════════════════════

class _IncidentCard extends StatelessWidget {
  final Incident incident;
  final VoidCallback? onAction;
  final VoidCallback? onDelete;
  const _IncidentCard({required this.incident, this.onAction, this.onDelete});

  static const _typeColors = {
    IncidentType.scrapped:       AppColors.error,
    IncidentType.discounted:     AppColors.warning,
    IncidentType.inRepair:       AppColors.info,
    IncidentType.returnSupplier: Color(0xFF8B5CF6),
  };

  static const _typeIcons = {
    IncidentType.scrapped:       Icons.delete_forever_rounded,
    IncidentType.discounted:     Icons.sell_rounded,
    IncidentType.inRepair:       Icons.build_rounded,
    IncidentType.returnSupplier: Icons.undo_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final color = _typeColors[incident.type] ?? AppColors.error;
    final icon  = _typeIcons[incident.type] ?? Icons.warning_rounded;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
              color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(9)),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(incident.productName, style: const TextStyle(fontSize: 13,
              fontWeight: FontWeight.w700, color: AppColors.textPrimary),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Wrap(spacing: 6, runSpacing: 4, children: [
            _TypeBadge(incident.type.label, color),
            _TypeBadge('×${incident.quantity}', AppColors.textSecondary),
            _TypeBadge(incident.status.label,
                incident.isPending ? AppColors.error
                    : incident.isResolved ? AppColors.secondary
                    : AppColors.info),
          ]),
          if (incident.repairCost > 0) ...[
            const SizedBox(height: 2),
            Text('Coût : ${CurrencyFormatter.format(incident.repairCost)}',
                style: const TextStyle(fontSize: 10, color: AppColors.warning)),
          ],
        ])),
        if (onDelete != null)
          GestureDetector(
            onTap: onDelete,
            child: Padding(padding: const EdgeInsets.all(6),
                child: Icon(Icons.delete_outline_rounded, size: 16,
                    color: AppColors.error.withOpacity(0.6))),
          ),
        if (onAction != null)
          GestureDetector(
            onTap: onAction,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8)),
              child: Text('Traiter', style: TextStyle(fontSize: 11,
                  fontWeight: FontWeight.w600, color: AppColors.primary)),
            ),
          ),
      ]),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  final String text; final Color color;
  const _TypeBadge(this.text, this.color);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
        color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
    child: Text(text, style: TextStyle(fontSize: 10,
        fontWeight: FontWeight.w600, color: color)),
  );
}

// ═══ Sheet de résolution ════════════════════════════════════════════════════

class _ResolveSheet extends StatefulWidget {
  final Incident incident;
  final String shopId;
  final VoidCallback onResolved;
  const _ResolveSheet({required this.incident, required this.shopId,
    required this.onResolved});
  @override State<_ResolveSheet> createState() => _ResolveSheetState();
}

class _ResolveSheetState extends State<_ResolveSheet> {
  late IncidentType _resolution;
  final _costCtrl  = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _resolution = widget.incident.type;
    _costCtrl.text = widget.incident.repairCost > 0
        ? widget.incident.repairCost.toStringAsFixed(0) : '';
    _priceCtrl.text = widget.incident.salePrice > 0
        ? widget.incident.salePrice.toStringAsFixed(0) : '';
    _notesCtrl.text = widget.incident.notes ?? '';
  }

  @override
  void dispose() { _costCtrl.dispose(); _priceCtrl.dispose(); _notesCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Center(child: Container(width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),

          // Header
          Row(children: [
            Container(width: 34, height: 34,
                decoration: BoxDecoration(
                    color: AppColors.error.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(Icons.warning_rounded, size: 17, color: AppColors.error)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Résolution d\'incident',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              Text(widget.incident.productName,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ])),
          ]),
          const SizedBox(height: 20),

          // Choix de résolution
          const Align(alignment: Alignment.centerLeft,
              child: Text('Action à appliquer',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary))),
          const SizedBox(height: 8),
          ...IncidentType.values.map((t) => _ResolutionTile(
            type: t, selected: _resolution == t,
            onTap: () => setState(() => _resolution = t),
          )),
          const SizedBox(height: 16),

          // Champs conditionnels
          if (_resolution == IncidentType.inRepair) ...[
            _Field(label: 'Coût de réparation', ctrl: _costCtrl,
                hint: '0', icon: Icons.payments_rounded, isNumber: true),
            const SizedBox(height: 10),
          ],
          if (_resolution == IncidentType.discounted) ...[
            _Field(label: 'Prix réduit de vente', ctrl: _priceCtrl,
                hint: '0', icon: Icons.sell_rounded, isNumber: true),
            const SizedBox(height: 10),
          ],
          _Field(label: 'Notes', ctrl: _notesCtrl,
              hint: 'Observation...', icon: Icons.notes_rounded),
          const SizedBox(height: 20),

          // Boutons
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: const BorderSide(color: AppColors.divider),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: const Text('Annuler'),
            )),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton.icon(
              onPressed: _resolve,
              icon: const Icon(Icons.check_circle_rounded, size: 16),
              label: const Text('Résoudre'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.secondary, foregroundColor: Colors.white,
                elevation: 0, padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            )),
          ]),
        ]),
      ),
    );
  }

  void _resolve() async {
    final now   = DateTime.now();
    final cost  = double.tryParse(_costCtrl.text) ?? 0;
    final price = double.tryParse(_priceCtrl.text) ?? 0;
    final inc   = widget.incident;
    final pid   = inc.productId ?? '';
    final vid   = inc.variantId ?? '';

    // Mettre à jour l'incident
    final resolved = Incident(
      id: inc.id, shopId: inc.shopId,
      productId: inc.productId, variantId: inc.variantId,
      productName: inc.productName, type: _resolution,
      status: IncidentStatus.resolved, quantity: inc.quantity,
      repairCost: cost, salePrice: price,
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
      receptionId: inc.receptionId,
      resolvedAt: now, createdBy: inc.createdBy,
      createdAt: inc.createdAt,
    );
    HiveBoxes.incidentsBox.put(resolved.id, resolved.toMap());

    // Actions via StockService
    switch (_resolution) {
      case IncidentType.scrapped:
        // blocked → sortie définitive (physical − qty, blocked − qty)
        await StockService.incidentRemove(
          shopId: widget.shopId, productId: pid, variantId: vid,
          quantity: inc.quantity, resolution: 'scrapped',
          incidentId: inc.id);
        _updateProductStatus(ProductStatus.scrapped);

      case IncidentType.discounted:
        // blocked → available (remis en vente à prix réduit)
        await StockService.incidentToAvailable(
          shopId: widget.shopId, productId: pid, variantId: vid,
          quantity: inc.quantity, resolution: 'discounted',
          incidentId: inc.id);
        _updateProductStatus(ProductStatus.discounted);

      case IncidentType.inRepair:
        // blocked → available (réparation réussie)
        await StockService.incidentToAvailable(
          shopId: widget.shopId, productId: pid, variantId: vid,
          quantity: inc.quantity, resolution: 'repair_success',
          incidentId: inc.id);
        _updateProductStatus(ProductStatus.available);

      case IncidentType.returnSupplier:
        // blocked → sortie (retour fournisseur)
        await StockService.incidentRemove(
          shopId: widget.shopId, productId: pid, variantId: vid,
          quantity: inc.quantity, resolution: 'return_supplier',
          incidentId: inc.id);
        _updateProductStatus(ProductStatus.returned);
    }

    Navigator.of(context).pop();
    widget.onResolved();
    if (mounted) AppSnack.success(context, 'Incident résolu');
  }

  void _updateProductStatus(ProductStatus newStatus) {
    if (widget.incident.productId == null) return;
    final products = AppDatabase.getProductsForShop(widget.shopId);
    final p = products.where((p) => p.id == widget.incident.productId).firstOrNull;
    if (p != null) AppDatabase.saveProduct(p.copyWith(status: newStatus), skipValidation: true);
  }
}

class _ResolutionTile extends StatelessWidget {
  final IncidentType type;
  final bool selected;
  final VoidCallback onTap;
  const _ResolutionTile({required this.type, required this.selected,
    required this.onTap});

  static const _colors = {
    IncidentType.scrapped:       AppColors.error,
    IncidentType.discounted:     AppColors.warning,
    IncidentType.inRepair:       AppColors.info,
    IncidentType.returnSupplier: Color(0xFF8B5CF6),
  };
  static const _icons = {
    IncidentType.scrapped:       Icons.delete_forever_rounded,
    IncidentType.discounted:     Icons.sell_rounded,
    IncidentType.inRepair:       Icons.build_rounded,
    IncidentType.returnSupplier: Icons.undo_rounded,
  };
  static const _descs = {
    IncidentType.scrapped:       'Retirer définitivement du stock',
    IncidentType.discounted:     'Remettre en vente à prix réduit',
    IncidentType.inRepair:       'Envoyer en réparation (coût enregistré)',
    IncidentType.returnSupplier: 'Retourner au fournisseur',
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[type]!;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? color.withOpacity(0.08) : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? color : AppColors.divider,
              width: selected ? 1.5 : 1),
        ),
        child: Row(children: [
          Icon(_icons[type], size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(type.label, style: TextStyle(fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: AppColors.textPrimary)),
            Text(_descs[type]!, style: const TextStyle(fontSize: 10,
                color: AppColors.textHint)),
          ])),
          if (selected) Icon(Icons.check_circle_rounded, size: 18, color: color),
        ]),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label, hint;
  final IconData icon;
  final TextEditingController ctrl;
  final bool isNumber;
  const _Field({required this.label, required this.hint,
    required this.icon, required this.ctrl, this.isNumber = false});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 12,
          fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
      const SizedBox(height: 4),
      TextField(
        controller: ctrl,
        keyboardType: isNumber ? TextInputType.number : TextInputType.text,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
          prefixIcon: Icon(icon, size: 16, color: AppColors.textHint),
          filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.divider)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AppColors.divider)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
        ),
      ),
    ],
  );
}
