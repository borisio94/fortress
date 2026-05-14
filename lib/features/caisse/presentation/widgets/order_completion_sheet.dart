import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/widgets/back_dated_picker.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../bloc/caisse_bloc.dart' show OrderFee;

/// Qui a effectivement encaissé le client pour cette commande ?
/// - `boutique` : flux d'argent normal — la boutique a la cash en main.
/// - `partnerNotRemitted` : le partenaire a encaissé pour le compte de la
///   boutique mais n'a pas encore versé. Génère une dette ledger
///   (saleCollected) pour le partenaire.
enum CollectedBy { boutique, partnerNotRemitted }

/// Résultat du sheet "Finaliser commande" (passage processing → completed).
/// Capture les frais de livraison/emballage payés par le client + qui a
/// physiquement encaissé l'argent (pour la gestion des dettes partenaires).
class OrderCompletionResult {
  final List<OrderFee> fees;
  final CollectedBy collectedBy;
  /// Date d'encaissement effective. Antidatable pour numériser une vente
  /// passée. Si null, le caller stamp `DateTime.now()` (comportement
  /// historique).
  final DateTime? completedAt;
  const OrderCompletionResult({
    required this.fees,
    required this.collectedBy,
    this.completedAt,
  });
}

Future<OrderCompletionResult?> showOrderCompletionSheet(
  BuildContext context, {
  List<OrderFee> initialFees = const [],
  /// Choix par défaut du radio "Qui a encaissé ?". Le caller positionne
  /// `partnerNotRemitted` si la commande est en mode partner, `boutique`
  /// sinon. L'opérateur peut toujours changer manuellement.
  CollectedBy defaultCollectedBy = CollectedBy.boutique,
  /// Nom du partenaire pour clarifier le libellé du radio (ex:
  /// « Partenaire (Dépôt Flash Douala) — pas encore versé »).
  String? partnerName,
}) {
  return showFormSheet<OrderCompletionResult>(
    context: context,
    builder: (_) => _OrderCompletionSheet(
      initialFees:        initialFees,
      defaultCollectedBy: defaultCollectedBy,
      partnerName:        partnerName,
    ),
  );
}

class _OrderCompletionSheet extends StatefulWidget {
  final List<OrderFee> initialFees;
  final CollectedBy    defaultCollectedBy;
  final String?        partnerName;
  const _OrderCompletionSheet({
    required this.initialFees,
    required this.defaultCollectedBy,
    this.partnerName,
  });
  @override
  State<_OrderCompletionSheet> createState() => _OrderCompletionSheetState();
}

class _OrderCompletionSheetState extends State<_OrderCompletionSheet> {
  late List<_FeeRow> _rows;
  late CollectedBy   _collectedBy;
  /// Date d'encaissement choisie par l'opérateur. Initialisée à now() ;
  /// modifiable via picker pour antidater une vente passée.
  late DateTime      _completedAt;

  @override
  void initState() {
    super.initState();
    _collectedBy = widget.defaultCollectedBy;
    _completedAt = DateTime.now();
    _rows = widget.initialFees.map((f) => _FeeRow(
      id:      f.id,
      label:   TextEditingController(text: f.label),
      amount:  TextEditingController(text: f.amount.toString()),
    )).toList();
  }

  Future<void> _pickCompletedAt() async {
    final d = await pickBackDateTime(
      context: context,
      initial: _completedAt,
      helpText: 'Date d\'encaissement',
    );
    if (d == null) return;
    setState(() => _completedAt = d);
  }

  /// Formate la date affichée dans le picker tile. Aujourd'hui → "Aujourd'hui
  /// à 14h30" pour ne pas alarmer le marchand qui finalise en temps réel.
  /// Sinon → "26 mars 2026 à 14h30" pour rendre l'antidatage visible.
  String _formatCompletedAt(DateTime d) {
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month
        && d.day == now.day;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    if (sameDay) return 'Aujourd\'hui à ${hh}h$mm';
    return DateFormat('d MMMM yyyy', 'fr_FR').format(d) + ' à ${hh}h$mm';
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.label.dispose();
      r.amount.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    setState(() {
      _rows.add(_FeeRow(
        id:     DateTime.now().microsecondsSinceEpoch.toString(),
        label:  TextEditingController(text: 'Livraison'),
        amount: TextEditingController(),
      ));
    });
  }

  void _removeRow(_FeeRow r) {
    setState(() {
      _rows.remove(r);
      r.label.dispose();
      r.amount.dispose();
    });
  }

  double get _total => _rows.fold<double>(
      0, (s, r) => s + (double.tryParse(r.amount.text.trim()) ?? 0));

  void _confirm() {
    final fees = <OrderFee>[];
    for (final r in _rows) {
      final amt = double.tryParse(r.amount.text.trim()) ?? 0;
      final lbl = r.label.text.trim();
      if (amt <= 0 && lbl.isEmpty) continue; // ligne vide → skip
      fees.add(OrderFee(
        id:     r.id,
        label:  lbl.isEmpty ? 'Frais' : lbl,
        amount: amt,
      ));
    }
    Navigator.of(context).pop(OrderCompletionResult(
      fees: fees, collectedBy: _collectedBy,
      completedAt: _completedAt));
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Finaliser la commande',
      icon:  Icons.check_circle_outline_rounded,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Qui a encaissé le client ?',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.55)),
                ),
                const SizedBox(height: 4),
                _CollectedByRadio(
                  value: _collectedBy,
                  partnerName: widget.partnerName,
                  onChanged: (v) => setState(() => _collectedBy = v),
                ),
                const SizedBox(height: 16),
                // ── Picker date d'encaissement (antidatable) ─────────
                // Permet à un marchand de finaliser une vente passée
                // (numérisation historique). Bornes via pickBackDateTime
                // (firstDate=2020, lastDate=now+1j).
                Text('Date d\'encaissement',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        color: Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: 0.55))),
                const SizedBox(height: 6),
                InkWell(
                  onTap: _pickCompletedAt,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(8),
                      border:
                          Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Row(children: [
                      Icon(Icons.event_rounded,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_formatCompletedAt(_completedAt),
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ),
                      Icon(Icons.edit_calendar_outlined,
                          size: 14,
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.4)),
                    ]),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Renseigne les frais (livraison, emballage…) inclus dans '
                  'le montant payé par le client.',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 12),
                ..._rows.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(flex: 3, child: TextField(
                      controller: r.label,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: 'Libellé',
                        labelStyle: TextStyle(fontSize: 11),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        border: OutlineInputBorder(),
                      ),
                    )),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: TextField(
                      controller: r.amount,
                      keyboardType: TextInputType.text,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.]')),
                      ],
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: 'Montant',
                        labelStyle: TextStyle(fontSize: 11),
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        border: OutlineInputBorder(),
                      ),
                    )),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      tooltip: 'Retirer',
                      onPressed: () => _removeRow(r),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                          minWidth: 32, minHeight: 32),
                    ),
                  ]),
                )),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _addRow,
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Ajouter un frais'),
                    style: TextButton.styleFrom(
                        foregroundColor: sem.brand,
                        padding: EdgeInsets.zero),
                  ),
                ),
                if (_rows.isNotEmpty) ...[
                  const Divider(height: 24),
                  Row(children: [
                    const Text('Total des frais',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text(CurrencyFormatter.format(_total),
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800,
                            color: sem.brand)),
                  ]),
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
                  label: const Text('Finaliser'),
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

class _FeeRow {
  final String id;
  final TextEditingController label;
  final TextEditingController amount;
  _FeeRow({required this.id, required this.label, required this.amount});
}

class _CollectedByRadio extends StatelessWidget {
  final CollectedBy value;
  final String? partnerName;
  final ValueChanged<CollectedBy> onChanged;
  const _CollectedByRadio({
    required this.value, required this.onChanged, this.partnerName,
  });
  @override
  Widget build(BuildContext context) {
    final partnerLabel = (partnerName == null || partnerName!.isEmpty)
        ? 'Partenaire — pas encore versé'
        : 'Partenaire ($partnerName) — pas encore versé';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RadioRow(
          label:    'Boutique (encaissement direct)',
          selected: value == CollectedBy.boutique,
          onTap:    () => onChanged(CollectedBy.boutique),
        ),
        _RadioRow(
          label:    partnerLabel,
          selected: value == CollectedBy.partnerNotRemitted,
          onTap:    () => onChanged(CollectedBy.partnerNotRemitted),
        ),
      ],
    );
  }
}

class _RadioRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RadioRow({
    required this.label, required this.selected, required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(children: [
          SizedBox(
            width: 18, height: 18,
            child: Radio<bool>(
              value: true, groupValue: selected,
              onChanged: (_) => onTap(),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: sem.brand,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? sem.brandText
                                  : const Color(0xFF111827)))),
        ]),
      ),
    );
  }
}
