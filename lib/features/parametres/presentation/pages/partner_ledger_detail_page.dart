import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/back_dated_picker.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../domain/entities/partner_ledger_entry.dart';

/// Détail du compte d'un partenaire :
/// - Solde actuel + bandeau "qui doit qui"
/// - Bouton "Enregistrer un versement" (boutique ↔ partenaire)
/// - Historique chronologique des mouvements (commandes + versements)
class PartnerLedgerDetailPage extends ConsumerStatefulWidget {
  final String shopId;
  final String partnerLocationId;
  const PartnerLedgerDetailPage({
    super.key, required this.shopId, required this.partnerLocationId,
  });
  @override
  ConsumerState<PartnerLedgerDetailPage> createState() =>
      _PartnerLedgerDetailPageState();
}

class _PartnerLedgerDetailPageState
    extends ConsumerState<PartnerLedgerDetailPage> {
  late void Function(String, String) _listener;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (sid != widget.shopId) return;
      if (table == 'partner_ledger_entries') setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  String get _partnerName {
    try {
      final raw = HiveBoxes.stockLocationsBox.get(widget.partnerLocationId);
      if (raw == null) return 'Partenaire';
      final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
      return loc.name;
    } catch (_) { return 'Partenaire'; }
  }

  /// Confirme + supprime une entrée du partner_ledger. Utile pour
  /// corriger une saisie erronée (ex: faux saleCollected créé par le bug
  /// sync amount_paid). Pas de cascade : si l'entrée est liée à une
  /// commande (`orderId`), la commande reste intacte.
  Future<void> _confirmDeleteEntry(PartnerLedgerEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce mouvement ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.type.labelFr,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Montant : '
                '${entry.amount >= 0 ? '+' : '−'}'
                '${CurrencyFormatter.format(entry.amount.abs())}',
                style: const TextStyle(fontSize: 12)),
            if ((entry.note ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(entry.note!,
                  style: TextStyle(
                      fontSize: 11, color: AppColors.textHint)),
            ],
            const SizedBox(height: 10),
            Text(
                'Cette suppression est irréversible et impactera '
                'directement le solde du partenaire.',
                style: TextStyle(
                    fontSize: 11, color: AppColors.error)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await PartnerLedgerService.deleteEntry(entry.id, widget.shopId);
    if (mounted) {
      AppSnack.success(context, 'Mouvement supprimé');
    }
  }

  Future<void> _registerRemittance() async {
    final res = await showFormSheet<_RemittanceResult>(
      context: context,
      builder: (_) => _RemittanceSheet(partnerName: _partnerName),
    );
    if (res == null || !mounted) return;
    // Convention : direction = partnerToBoutique → +amount (réduit la dette
    // que le partenaire avait envers nous) ; boutiqueToPartner → -amount.
    final signed = res.direction == _RemittanceDirection.partnerToBoutique
        ? -res.amount.abs()  // diminue le crédit (partenaire a payé)
        : res.amount.abs();  // augmente la dette (boutique a payé)
    // Petit raisonnement : si solde était +100 (partenaire nous doit 100)
    // et que partenaire verse 100, on doit ajouter -100 → solde = 0.
    // À l'inverse, si solde était -50 (on lui doit 50) et qu'on lui verse
    // 50, on ajoute +50 → solde = 0.
    await PartnerLedgerService.addEntry(
      shopId:            widget.shopId,
      partnerLocationId: widget.partnerLocationId,
      type:              PartnerLedgerEntryType.remittance,
      amount:            signed,
      note:              res.note?.isEmpty == true ? null : res.note,
      createdAt:         res.createdAt,
    );
    if (mounted) {
      AppSnack.success(context, 'Versement enregistré.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = PartnerLedgerService.entriesForShop(widget.shopId,
        partnerLocationId: widget.partnerLocationId);
    final balance = PartnerLedgerService.balanceForPartner(
        widget.shopId, widget.partnerLocationId);
    final sem = Theme.of(context).semantic;
    final partnerOwes = balance > 0;
    final boutiqueOwes = balance < 0;
    final color = partnerOwes
        ? sem.success
        : (boutiqueOwes ? sem.danger : AppColors.textHint);
    final tag = partnerOwes
        ? 'Le partenaire vous doit'
        : (boutiqueOwes
            ? 'Vous devez au partenaire'
            : 'Comptes à jour');

    return Scaffold(
      appBar: AppBar(
        title: Text(_partnerName,
            style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Column(children: [
        // Bandeau solde
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          color: color.withValues(alpha: 0.06),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tag,
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: color.withValues(alpha: 0.85))),
              const SizedBox(height: 4),
              Text(
                CurrencyFormatter.format(balance.abs()),
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w800,
                    color: color),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _registerRemittance,
              icon: const Icon(Icons.payments_outlined, size: 18),
              label: const Text('Enregistrer un versement'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 44),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text('Aucun mouvement',
                  style: TextStyle(color: AppColors.textHint)))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1, color: Color(0xFFF0F0F0)),
                  itemBuilder: (_, i) => _MovementTile(
                    entry: entries[i],
                    onDelete: () => _confirmDeleteEntry(entries[i]),
                  ),
                ),
        ),
      ]),
    );
  }
}

class _MovementTile extends StatelessWidget {
  final PartnerLedgerEntry entry;
  final VoidCallback?      onDelete;
  const _MovementTile({required this.entry, this.onDelete});
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final isPositive = entry.amount >= 0;
    final color = isPositive ? sem.success : sem.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(_iconFor(entry.type), size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
          Text(entry.type.labelFr,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600,
                  color: Color(0xFF111827))),
          if ((entry.note ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(entry.note!,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: AppColors.textHint)),
          ],
          const SizedBox(height: 2),
          Text(_fmtDate(entry.createdAt),
              style: TextStyle(fontSize: 10.5, color: AppColors.textHint)),
        ])),
        const SizedBox(width: 8),
        Text(
          (isPositive ? '+' : '−')
              + CurrencyFormatter.format(entry.amount.abs()),
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w800, color: color),
        ),
        // Menu suppression — discret (3 points). Visible si onDelete fourni.
        if (onDelete != null) ...[
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: 'Options',
            icon: Icon(Icons.more_vert_rounded,
                size: 18, color: AppColors.textHint),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onSelected: (v) {
              if (v == 'delete') onDelete!();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'delete',
                child: Row(children: [
                  Icon(Icons.delete_outline_rounded,
                      size: 16, color: AppColors.error),
                  const SizedBox(width: 8),
                  Text('Supprimer',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.error)),
                ]),
              ),
            ],
          ),
        ],
      ]),
    );
  }

  IconData _iconFor(PartnerLedgerEntryType t) => switch (t) {
        PartnerLedgerEntryType.saleCollected => Icons.shopping_bag_outlined,
        PartnerLedgerEntryType.deliveryOwed  => Icons.local_shipping_outlined,
        PartnerLedgerEntryType.remittance    => Icons.payments_outlined,
      };

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}

// ─── Sheet de versement ────────────────────────────────────────────────────

enum _RemittanceDirection { partnerToBoutique, boutiqueToPartner }

class _RemittanceResult {
  final double amount;
  final _RemittanceDirection direction;
  final String? note;
  /// Date du versement (antidatable). Si null, le caller stamp `now()`.
  final DateTime? createdAt;
  const _RemittanceResult({
    required this.amount, required this.direction, this.note,
    this.createdAt,
  });
}

class _RemittanceSheet extends StatefulWidget {
  final String partnerName;
  const _RemittanceSheet({required this.partnerName});
  @override
  State<_RemittanceSheet> createState() => _RemittanceSheetState();
}

class _RemittanceSheetState extends State<_RemittanceSheet> {
  _RemittanceDirection _direction = _RemittanceDirection.partnerToBoutique;
  final _amountCtrl = TextEditingController();
  final _noteCtrl   = TextEditingController();
  String? _error;
  /// Date du versement (antidatable). Défaut = now(). Modifiable via picker
  /// pour numériser un versement passé.
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final amt = double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    if (amt == null || amt <= 0) {
      setState(() => _error = 'Montant invalide.');
      return;
    }
    Navigator.of(context).pop(_RemittanceResult(
      amount:    amt,
      direction: _direction,
      note:      _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      createdAt: _date,
    ));
  }

  Future<void> _pickDate() async {
    final d = await pickBackDate(
      context: context,
      initial: _date,
      helpText: 'Date du versement',
    );
    if (d != null) setState(() => _date = d);
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Enregistrer un versement',
      icon:  Icons.payments_outlined,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _SectionLabel('Sens du versement'),
                _DirRow(
                  selected: _direction == _RemittanceDirection.partnerToBoutique,
                  label: '${widget.partnerName} → Boutique',
                  hint:  'Le partenaire vous remet de l\'argent',
                  onTap: () => setState(() =>
                      _direction = _RemittanceDirection.partnerToBoutique),
                ),
                _DirRow(
                  selected: _direction == _RemittanceDirection.boutiqueToPartner,
                  label: 'Boutique → ${widget.partnerName}',
                  hint:  'Vous payez le partenaire (frais de livraison…)',
                  onTap: () => setState(() =>
                      _direction = _RemittanceDirection.boutiqueToPartner),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Montant (FCFA)'),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppColors.divider)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Date du versement'),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(8),
                      border: const Border.fromBorderSide(
                          BorderSide(color: AppColors.divider)),
                    ),
                    child: Row(children: [
                      Icon(Icons.event_rounded,
                          size: 14, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            DateFormat('d MMMM yyyy', 'fr_FR')
                                .format(_date),
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ),
                      Icon(Icons.edit_calendar_outlined,
                          size: 12,
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.4)),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Note (optionnel)'),
                TextField(
                  controller: _noteCtrl,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'N° de reçu, motif…',
                    hintStyle: const TextStyle(
                        fontSize: 12, color: Color(0xFFBBBBBB)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: AppColors.divider)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).semantic.danger)),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44)),
                  child: const Text('Annuler'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Enregistrer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.55))),
      );
}

class _DirRow extends StatelessWidget {
  final bool selected;
  final String label;
  final String hint;
  final VoidCallback onTap;
  const _DirRow({
    required this.selected, required this.label,
    required this.hint, required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? sem.brandSurface : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? sem.brand.withValues(alpha: 0.4)
                              : sem.borderSubtle),
        ),
        child: Row(children: [
          Icon(selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? sem.brand : const Color(0xFF9CA3AF)),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? sem.brandText
                                    : const Color(0xFF111827))),
            const SizedBox(height: 1),
            Text(hint,
                style: TextStyle(fontSize: 11, color: AppColors.textHint)),
          ])),
        ]),
      ),
    );
  }
}
