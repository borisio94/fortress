import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../bloc/caisse_bloc.dart' show OrderFee;

/// Résultat de [showOrderFeesSheet] : les frais de la commande + une éventuelle
/// dépense additionnelle à régler au partenaire-livreur.
///
/// La dépense partenaire est OPTIONNELLE et n'est proposée que lorsque la
/// commande est livrée par un partenaire (cf. `allowPartnerExpense`). Elle est
/// distincte des frais : alors que les frais sont des coûts ABSORBÉS par la
/// boutique (ils n'alimentent aucun ledger), la dépense partenaire crée une
/// entrée `deliveryOwed` négative dans le partner_ledger — compensée
/// automatiquement au prochain versement du partenaire.
class OrderFeesResult {
  final List<OrderFee> fees;

  /// Montant de la dépense à régler au partenaire (> 0) ou null si l'opérateur
  /// n'en a pas saisi.
  final double? partnerExpenseAmount;

  /// Motif de la dépense partenaire (traçabilité). null si pas de dépense.
  final String? partnerExpenseLabel;

  const OrderFeesResult({
    required this.fees,
    this.partnerExpenseAmount,
    this.partnerExpenseLabel,
  });

  bool get hasPartnerExpense =>
      partnerExpenseAmount != null && partnerExpenseAmount! > 0;
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
///
/// Dépense partenaire (fusion de l'ancien bouton « $ ») : si
/// [allowPartnerExpense] est vrai, une section dépliable « Dépense à régler au
/// partenaire » apparaît en bas. Elle remplace l'ancien dialog dédié
/// `AddOrderExpenseDialog` — un seul point d'entrée pour tous les coûts d'une
/// commande, sans risquer d'oublier la mise à jour du ledger.
Future<OrderFeesResult?> showOrderFeesSheet(
  BuildContext context, {
  List<OrderFee> initialFees = const [],
  bool allowPartnerExpense = false,
  String? partnerName,
}) {
  return showFormSheet<OrderFeesResult>(
    context: context,
    builder: (_) => _OrderFeesSheet(
      initialFees: initialFees,
      allowPartnerExpense: allowPartnerExpense,
      partnerName: partnerName,
    ),
  );
}

class _OrderFeesSheet extends StatefulWidget {
  final List<OrderFee> initialFees;
  final bool allowPartnerExpense;
  final String? partnerName;
  const _OrderFeesSheet({
    required this.initialFees,
    this.allowPartnerExpense = false,
    this.partnerName,
  });
  @override
  State<_OrderFeesSheet> createState() => _OrderFeesSheetState();
}

class _OrderFeesSheetState extends State<_OrderFeesSheet> {
  late List<_FeeRow> _rows;

  // Dépense partenaire (optionnelle) — repliée par défaut.
  bool _expenseOpen = false;
  final _expenseAmount = TextEditingController();
  final _expenseLabel = TextEditingController(text: 'Frais supplémentaires');
  String? _expenseError;

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
    _expenseAmount.dispose();
    _expenseLabel.dispose();
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

    // Dépense partenaire : valider seulement si la section est ouverte ET
    // qu'un montant a été saisi. Une section ouverte mais vide est ignorée.
    double? expenseAmount;
    String? expenseLabel;
    if (widget.allowPartnerExpense && _expenseOpen) {
      final raw = _expenseAmount.text.trim().replaceAll(',', '.');
      final hasInput = raw.isNotEmpty || _expenseLabel.text.trim().isNotEmpty;
      if (hasInput) {
        final value = double.tryParse(raw);
        if (value == null || value <= 0) {
          setState(() => _expenseError = 'Montant de la dépense invalide');
          return;
        }
        final lbl = _expenseLabel.text.trim();
        if (lbl.isEmpty) {
          setState(() => _expenseError = 'Motif de la dépense requis');
          return;
        }
        expenseAmount = value;
        expenseLabel = lbl;
      }
    }

    if (!mounted) return;
    Navigator.of(context).pop(OrderFeesResult(
      fees: fees,
      partnerExpenseAmount: expenseAmount,
      partnerExpenseLabel: expenseLabel,
    ));
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
                if (widget.allowPartnerExpense) _buildPartnerExpense(context),
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

  /// Section « Dépense à régler au partenaire » — remplace l'ancien bouton $.
  /// Repliée par défaut : un simple bouton « + Dépense partenaire » qui
  /// déplie le formulaire (montant + motif) au tap.
  Widget _buildPartnerExpense(BuildContext context) {
    final theme = Theme.of(context);
    final partner = (widget.partnerName ?? '').trim();
    if (!_expenseOpen) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _expenseOpen = true),
            icon: const Icon(Icons.attach_money_rounded, size: 16),
            label: const Text('Dépense à régler au partenaire'),
            style: TextButton.styleFrom(
                foregroundColor: AppColors.warning, padding: EdgeInsets.zero),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Icon(Icons.attach_money_rounded,
                size: 16, color: AppColors.warning),
            const SizedBox(width: 6),
            const Expanded(
              child: Text('Dépense à régler au partenaire',
                  style: AppTextStyles.bodyBold),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 16),
              tooltip: 'Annuler la dépense',
              onPressed: () => setState(() {
                _expenseOpen = false;
                _expenseError = null;
                _expenseAmount.clear();
              }),
              padding: EdgeInsets.zero,
              constraints:
                  const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            partner.isEmpty
                ? 'Enregistré comme dette envers le partenaire et déduit '
                    'automatiquement de son prochain versement.'
                : 'Enregistré comme dette envers « $partner » et déduit '
                    'automatiquement de son prochain versement.',
            style: AppTextStyles.captionHint.copyWith(
                height: 1.4,
                color:
                    theme.colorScheme.onSurface.withValues(alpha: 0.75)),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _expenseLabel,
                style: AppTextStyles.body,
                decoration: const InputDecoration(
                  labelText: 'Motif',
                  labelStyle: AppTextStyles.caption,
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _expenseAmount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                style: AppTextStyles.body,
                decoration: const InputDecoration(
                  labelText: 'Montant',
                  labelStyle: AppTextStyles.caption,
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ]),
          if (_expenseError != null) ...[
            const SizedBox(height: 8),
            Text(_expenseError!,
                style: AppTextStyles.captionHint
                    .copyWith(color: theme.colorScheme.error)),
          ],
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
