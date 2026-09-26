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

  /// Prix de livraison FACTURÉ au client — entre dans le total à payer ET sur
  /// la facture (via `Sale.deliveryPrice`). Distinct des [fees] qui sont des
  /// coûts ABSORBÉS par la boutique (n'augmentent pas le total client).
  final int deliveryPrice;

  const OrderFeesResult({required this.fees, this.deliveryPrice = 0});
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
  /// Prix de livraison actuellement FACTURÉ au client (`Sale.deliveryPrice`).
  int initialDeliveryPrice = 0,
  /// Affiche le champ « Frais de livraison facturés » (masqué pour un retrait
  /// en boutique où il n'y a pas de livraison à facturer).
  bool showDeliveryPrice = true,
}) {
  return showFormSheet<OrderFeesResult>(
    context: context,
    builder: (_) => _OrderFeesSheet(
      initialFees: initialFees,
      initialDeliveryPrice: initialDeliveryPrice,
      showDeliveryPrice: showDeliveryPrice,
    ),
  );
}

class _OrderFeesSheet extends StatefulWidget {
  final List<OrderFee> initialFees;
  final int initialDeliveryPrice;
  final bool showDeliveryPrice;
  const _OrderFeesSheet({
    required this.initialFees,
    this.initialDeliveryPrice = 0,
    this.showDeliveryPrice = true,
  });
  @override
  State<_OrderFeesSheet> createState() => _OrderFeesSheetState();
}

class _OrderFeesSheetState extends State<_OrderFeesSheet> {
  late List<_FeeRow> _rows;
  late final TextEditingController _deliveryCtrl;

  static bool _isDeliveryLabel(String l) {
    final s = l.toLowerCase();
    return s.contains('livraison') || s.contains('delivery');
  }

  @override
  void initState() {
    super.initState();
    // Consolide TOUT ce qui concerne la livraison dans le champ FACTURÉ du
    // haut : le prix de livraison existant + tout frais (même saisi en
    // « absorbé ») étiqueté « livraison » — piège fréquent. Les autres frais
    // restent en absorbés.
    var deliveryFromFees = 0;
    final absorbed = <OrderFee>[];
    for (final f in widget.initialFees) {
      if (widget.showDeliveryPrice && _isDeliveryLabel(f.label)) {
        deliveryFromFees += f.amount.round();
      } else {
        absorbed.add(f);
      }
    }
    final initDelivery = widget.initialDeliveryPrice + deliveryFromFees;
    _deliveryCtrl = TextEditingController(
        text: initDelivery > 0 ? initDelivery.toString() : '');
    _rows = absorbed
        .map((f) => _FeeRow(
              id: f.id,
              label: TextEditingController(text: f.label),
              amount: TextEditingController(text: f.amount.toStringAsFixed(0)),
            ))
        .toList();
  }

  @override
  void dispose() {
    _deliveryCtrl.dispose();
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
        label: TextEditingController(text: 'Emballage'),
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
    var deliveryFromRows = 0;
    for (final r in _rows) {
      final amt = double.tryParse(r.amount.text.trim()) ?? 0;
      final lbl = r.label.text.trim();
      if (amt <= 0 && lbl.isEmpty) continue; // ligne vide → ignorée
      // Filet : une ligne « livraison » saisie dans les frais absorbés est
      // FACTURÉE (basculée dans le prix de livraison), jamais absorbée.
      if (widget.showDeliveryPrice && _isDeliveryLabel(lbl)) {
        deliveryFromRows += amt.round();
        continue;
      }
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
    final dp = widget.showDeliveryPrice
        ? ((double.tryParse(_deliveryCtrl.text.trim().replaceAll(',', '.'))
                ?.round() ?? 0) + deliveryFromRows)
        : widget.initialDeliveryPrice;
    Navigator.of(context).pop(OrderFeesResult(fees: fees, deliveryPrice: dp));
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
                if (widget.showDeliveryPrice) ...[
                  Text('Frais de livraison — facturés au client',
                      style: AppTextStyles.bodyBold),
                  const SizedBox(height: 3),
                  Text(
                    'Ce montant s\'AJOUTE au total à payer par le client et '
                    'apparaît sur la facture.',
                    style: AppTextStyles.caption.copyWith(
                        color: Theme.of(context)
                            .colorScheme.onSurface.withValues(alpha: 0.65)),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _deliveryCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                    onChanged: (_) => setState(() {}),
                    style: AppTextStyles.body,
                    decoration: InputDecoration(
                      labelText: 'Montant livraison',
                      suffixText: 'FCFA',
                      labelStyle: AppTextStyles.caption,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 10, vertical: 12),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const Divider(height: 26),
                ],
                Text(
                  widget.showDeliveryPrice
                      ? 'Autres dépenses (emballage…) — AJOUTÉES au total à '
                        'payer par le client.'
                      : 'Dépenses de la commande (livraison, emballage…) — '
                        'ajoutées au total à payer par le client.',
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
                              decoration: InputDecoration(
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
                              decoration: InputDecoration(
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
                    backgroundColor: AppColors.primaryFill,
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
