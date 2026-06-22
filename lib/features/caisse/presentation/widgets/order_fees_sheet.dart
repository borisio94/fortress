import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../bloc/caisse_bloc.dart' show OrderFee;

/// Résultat de [showOrderFeesSheet] : la liste des frais de la commande.
///
/// Les frais sont les coûts engagés sur la commande (livraison, emballage…).
/// Quand la commande est livrée par un partenaire, ces frais sont
/// automatiquement répercutés sur le livre partenaire (écriture `deliveryOwed`)
/// et déduits de son prochain versement — cette répercussion est gérée par
/// l'appelant (cf. `caisse_page._editFees`), pas dans ce sheet. Un seul point
/// de saisie pour tous les coûts d'une commande.
class OrderFeesResult {
  final List<OrderFee> fees;

  const OrderFeesResult({required this.fees});
}

/// Éditeur de frais d'une commande, indépendant du statut.
///
/// Règle métier : les frais de livraison sont souvent connus APRÈS la
/// complétion (le livreur revient et annonce le coût). On peut donc éditer
/// les frais à tout moment, y compris sur une commande déjà complétée — il
/// n'y a AUCUN verrouillage des frais (seuls les ARTICLES sont verrouillés
/// après complétion).
///
/// Garde-fou anti-doublon : si deux frais portent le même libellé (ex. deux
/// « Livraison »), on AVERTIT avec confirmation explicite — sans bloquer
/// (l'opérateur peut légitimement vouloir deux lignes).
Future<OrderFeesResult?> showOrderFeesSheet(
  BuildContext context, {
  List<OrderFee> initialFees = const [],
}) {
  return showFormSheet<OrderFeesResult>(
    context: context,
    builder: (_) => _OrderFeesSheet(initialFees: initialFees),
  );
}

class _OrderFeesSheet extends StatefulWidget {
  final List<OrderFee> initialFees;
  const _OrderFeesSheet({required this.initialFees});
  @override
  State<_OrderFeesSheet> createState() => _OrderFeesSheetState();
}

class _OrderFeesSheetState extends State<_OrderFeesSheet> {
  late List<_FeeRow> _rows;

  @override
  void initState() {
    super.initState();
    _rows = widget.initialFees
        .map((f) => _FeeRow(
              id: f.id,
              label: TextEditingController(text: f.label),
              amount: TextEditingController(text: f.amount.toStringAsFixed(0)),
            ))
        .toList();
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
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        label: TextEditingController(text: 'Livraison'),
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

  /// Premier libellé en doublon (insensible à la casse), ou null.
  String? _duplicateLabel(List<OrderFee> fees) {
    final seen = <String>{};
    for (final f in fees) {
      final key = f.label.trim().toLowerCase();
      if (key.isEmpty) continue;
      if (!seen.add(key)) return f.label.trim();
    }
    return null;
  }

  Future<void> _confirm() async {
    final fees = <OrderFee>[];
    for (final r in _rows) {
      final amt = double.tryParse(r.amount.text.trim()) ?? 0;
      final lbl = r.label.text.trim();
      if (amt <= 0 && lbl.isEmpty) continue; // ligne vide → ignorée
      fees.add(OrderFee(
        id: r.id,
        label: lbl.isEmpty ? 'Frais' : lbl,
        amount: amt,
      ));
    }

    // Garde-fou anti-doublon : avertir (sans bloquer) si un libellé revient.
    final dup = _duplicateLabel(fees);
    if (dup != null) {
      final keep = await showDialog<bool>(
        context: context,
        builder: (dc) => AlertDialog(
          title: const Text('Frais en double'),
          content: Text(
              'Un frais « $dup » existe déjà sur cette commande. '
              'Voulez-vous quand même l\'ajouter (double comptage possible) ?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dc).pop(false),
              child: const Text('Annuler'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.warning,
                  foregroundColor: Colors.white),
              onPressed: () => Navigator.of(dc).pop(true),
              child: const Text('Ajouter quand même'),
            ),
          ],
        ),
      );
      if (keep != true) return; // l'opérateur revient corriger
    }

    if (!mounted) return;
    Navigator.of(context).pop(OrderFeesResult(fees: fees));
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Modifier les frais',
      icon: Icons.local_shipping_outlined,
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
                  'Frais engagés sur la commande (livraison, emballage…). '
                  'Modifiable à tout moment, même après encaissement.',
                  style: AppTextStyles.bodySm.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 12),
                ..._rows.map((r) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(children: [
                        Expanded(
                            flex: 3,
                            child: TextField(
                              controller: r.label,
                              style: AppTextStyles.body,
                              decoration: const InputDecoration(
                                labelText: 'Libellé',
                                labelStyle: AppTextStyles.caption,
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 10),
                                border: OutlineInputBorder(),
                              ),
                            )),
                        const SizedBox(width: 8),
                        Expanded(
                            flex: 2,
                            child: TextField(
                              controller: r.amount,
                              keyboardType: const TextInputType
                                  .numberWithOptions(decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                    RegExp(r'[0-9.]')),
                              ],
                              onChanged: (_) => setState(() {}),
                              style: AppTextStyles.body,
                              decoration: const InputDecoration(
                                labelText: 'Montant',
                                labelStyle: AppTextStyles.caption,
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
                        foregroundColor: sem.brand, padding: EdgeInsets.zero),
                  ),
                ),
                if (_rows.isNotEmpty) ...[
                  const Divider(height: 24),
                  Row(children: [
                    const Text('Total des frais',
                        style: AppTextStyles.bodyBold),
                    const Spacer(),
                    Text(CurrencyFormatter.format(_total),
                        style: AppTextStyles.label.copyWith(
                            fontWeight: FontWeight.w800, color: sem.brand)),
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
                  style:
                      OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
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

class _FeeRow {
  final String id;
  final TextEditingController label;
  final TextEditingController amount;
  _FeeRow({required this.id, required this.label, required this.amount});
}
