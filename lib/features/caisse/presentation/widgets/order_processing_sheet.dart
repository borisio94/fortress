import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../domain/entities/sale.dart';

/// Résultat du sheet "Démarrer traitement" (passage scheduled → processing).
/// Capture le mode de paiement + le mode de livraison opérationnel.
/// Le PARTENAIRE n'est PAS demandé ici — il est déjà déterminé par le lieu
/// d'origine de la commande (`Sale.deliveryLocationId`), conformément au
/// principe "tout est rattaché à un lieu".
class OrderProcessingResult {
  final PaymentMethod paymentMethod;
  final DeliveryMode  mode;
  final String?       personName; // optionnel : nom livreur si inHouse
  /// Nouveau total encaissé après cette validation. Si null, le caller
  /// ne touche pas au paiement (comportement historique). Si non null,
  /// le caller appelle recordPayment(orderId, amountPaidTotal) pour
  /// mettre à jour `amount_paid` + `payment_status`.
  final double?       amountPaidTotal;
  const OrderProcessingResult({
    required this.paymentMethod,
    required this.mode,
    this.personName,
    this.amountPaidTotal,
  });
}

/// Helper d'ouverture. `defaultMode` est calculé par le caller selon le
/// lieu d'origine : partner si rattaché à un dépôt partenaire, inHouse
/// si rattaché à la boutique principale.
Future<OrderProcessingResult?> showOrderProcessingSheet(
  BuildContext context, {
  required DeliveryMode defaultMode,
  PaymentMethod? initialPaymentMethod,
  String? initialPersonName,
  String? originLocationName,
  double? orderTotal,
  double  amountAlreadyPaid = 0,
}) {
  return showFormSheet<OrderProcessingResult>(
    context: context,
    builder: (_) => _OrderProcessingSheet(
      defaultMode:          defaultMode,
      initialPaymentMethod: initialPaymentMethod,
      initialPersonName:    initialPersonName,
      originLocationName:   originLocationName,
      orderTotal:           orderTotal,
      amountAlreadyPaid:    amountAlreadyPaid,
    ),
  );
}

class _OrderProcessingSheet extends StatefulWidget {
  final DeliveryMode  defaultMode;
  final PaymentMethod? initialPaymentMethod;
  final String?       initialPersonName;
  final String?       originLocationName;
  final double?       orderTotal;
  final double        amountAlreadyPaid;
  const _OrderProcessingSheet({
    required this.defaultMode,
    this.initialPaymentMethod,
    this.initialPersonName,
    this.originLocationName,
    this.orderTotal,
    this.amountAlreadyPaid = 0,
  });
  @override
  State<_OrderProcessingSheet> createState() => _OrderProcessingSheetState();
}

class _OrderProcessingSheetState extends State<_OrderProcessingSheet> {
  late PaymentMethod _payment;
  late DeliveryMode  _mode;
  late final TextEditingController _personCtrl;
  // Suivi paiement à la validation (hotfix_065). Permet d'enregistrer un
  // versement (acompte ou solde) au passage scheduled → processing.
  _ProcessingPaymentChoice _paymentChoice = _ProcessingPaymentChoice.keepCurrent;
  late final TextEditingController _addedAmountCtrl;

  @override
  void initState() {
    super.initState();
    _payment    = widget.initialPaymentMethod ?? PaymentMethod.cash;
    _mode       = widget.defaultMode;
    _personCtrl = TextEditingController(text: widget.initialPersonName ?? '');
    _addedAmountCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _personCtrl.dispose();
    _addedAmountCtrl.dispose();
    super.dispose();
  }

  /// Vrai si la commande est déjà entièrement encaissée à l'ouverture
  /// du sheet (acompte total saisi à la création). Dans ce cas, le sheet
  /// ne montre QUE la section livraison — l'opérateur n'a pas à
  /// re-confirmer le paiement.
  bool get _isFullyPaid {
    final total = widget.orderTotal ?? 0;
    return total > 0 && widget.amountAlreadyPaid >= total;
  }

  /// Calcule le nouveau total encaissé selon le choix utilisateur :
  ///   • keepCurrent → null (caller ne touche pas au paiement)
  ///   • addPartial  → amountAlreadyPaid + montant saisi, capé au total
  ///   • markFull    → orderTotal (tout encaissé maintenant)
  double? _resolveAmountPaidTotal() {
    final total   = widget.orderTotal ?? 0;
    final already = widget.amountAlreadyPaid;
    switch (_paymentChoice) {
      case _ProcessingPaymentChoice.keepCurrent:
        return null;
      case _ProcessingPaymentChoice.markFull:
        return total;
      case _ProcessingPaymentChoice.addPartial:
        final v = double.tryParse(
            _addedAmountCtrl.text.trim().replaceAll(',', '.'));
        if (v == null || v <= 0) return null;
        return (already + v).clamp(0, total).toDouble();
    }
  }

  void _confirm() {
    final isPersonRelevant = _mode == DeliveryMode.inHouse
        || _mode == DeliveryMode.partner;
    final p = _personCtrl.text.trim();
    Navigator.of(context).pop(OrderProcessingResult(
      paymentMethod:    _payment,
      mode:             _mode,
      personName:       isPersonRelevant && p.isNotEmpty ? p : null,
      amountPaidTotal:  _resolveAmountPaidTotal(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveFormFrame(
      title: 'Démarrer le traitement',
      icon:  Icons.local_shipping_outlined,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Si la commande est DÉJÀ totalement payée (acompte boutique
                // = total à la création), on saute les sections paiement.
                // Le mode de paiement enregistré sur la Sale est conservé.
                // Seul le mode de livraison reste à choisir.
                if (!_isFullyPaid) ...[
                  _SectionLabel('Mode de paiement'),
                  _ChipsRow<PaymentMethod>(
                    values: PaymentMethod.values,
                    selected: _payment,
                    labelOf: _paymentLabel,
                    iconOf:  _paymentIcon,
                    onChanged: (v) => setState(() => _payment = v),
                  ),
                  const SizedBox(height: 14),
                ] else ...[
                  // Bandeau confirmation "déjà payé en intégralité" pour
                  // que l'opérateur sache pourquoi la section paiement
                  // disparaît.
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color(0xFF10B981)
                              .withValues(alpha: 0.3)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.check_circle_rounded,
                          size: 14, color: Color(0xFF10B981)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'Commande déjà encaissée en intégralité '
                            '(${_fmtMoney(widget.orderTotal!)})',
                            style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF065F46))),
                      ),
                    ]),
                  ),
                ],
                _SectionLabel('Mode de livraison'),
                if ((widget.originLocationName ?? '').isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Icon(_mode == DeliveryMode.partner
                              ? Icons.handshake_outlined
                              : Icons.storefront_outlined,
                          size: 13, color: const Color(0xFF6B7280)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Origine : ${widget.originLocationName}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF6B7280)),
                        ),
                      ),
                    ]),
                  ),
                ],
                _ChipsRow<DeliveryMode>(
                  values: const [
                    DeliveryMode.pickup,
                    DeliveryMode.inHouse,
                    DeliveryMode.partner,
                    DeliveryMode.shipment,
                  ],
                  selected: _mode,
                  labelOf: (m) => m.labelFr,
                  iconOf:  _modeIcon,
                  onChanged: (v) => setState(() => _mode = v),
                ),

                if (_mode == DeliveryMode.inHouse
                    || _mode == DeliveryMode.partner) ...[
                  const SizedBox(height: 14),
                  _SectionLabel(_mode == DeliveryMode.inHouse
                      ? 'Livreur (optionnel)'
                      : 'Contact partenaire (optionnel)'),
                  TextField(
                    controller: _personCtrl,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF111827)),
                    decoration: InputDecoration(
                      hintText: _mode == DeliveryMode.inHouse
                          ? 'Nom du livreur'
                          : 'Contact chez le partenaire',
                      hintStyle: const TextStyle(
                          color: Color(0xFFBBBBBB), fontSize: 12),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: Theme.of(context).semantic.borderSubtle)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.primary, width: 1.5)),
                    ),
                  ),
                ],
                if ((widget.orderTotal ?? 0) > 0 && !_isFullyPaid) ...[
                  const SizedBox(height: 16),
                  _SectionLabel(
                      'Paiement reçu — Total ${_fmtMoney(widget.orderTotal!)}'
                      '${widget.amountAlreadyPaid > 0
                          ? ' · déjà ${_fmtMoney(widget.amountAlreadyPaid)}'
                          : ''}'),
                  _ProcessingPaymentRow(
                    selected: _paymentChoice,
                    onChanged: (v) => setState(() => _paymentChoice = v),
                    hasAcompte: widget.amountAlreadyPaid > 0,
                  ),
                  if (_paymentChoice == _ProcessingPaymentChoice.addPartial) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _addedAmountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9.,]')),
                      ],
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                      decoration: InputDecoration(
                        hintText: 'Montant encaissé maintenant',
                        suffixText: CurrencyFormatter.currentSymbol,
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF9FAFB),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(
                                color: Theme.of(context).semantic.borderSubtle)),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
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
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Démarrer'),
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

  String _paymentLabel(PaymentMethod p) => switch (p) {
        PaymentMethod.cash        => 'Espèces',
        PaymentMethod.mobileMoney => 'Mobile Money',
        PaymentMethod.card        => 'Carte',
        PaymentMethod.credit      => 'Crédit',
      };

  IconData _paymentIcon(PaymentMethod p) => switch (p) {
        PaymentMethod.cash        => Icons.payments_outlined,
        PaymentMethod.mobileMoney => Icons.phone_iphone_rounded,
        PaymentMethod.card        => Icons.credit_card_rounded,
        PaymentMethod.credit      => Icons.account_balance_wallet_outlined,
      };

  IconData _modeIcon(DeliveryMode m) => switch (m) {
        DeliveryMode.pickup   => Icons.storefront_outlined,
        DeliveryMode.inHouse  => Icons.delivery_dining_outlined,
        DeliveryMode.partner  => Icons.handshake_outlined,
        DeliveryMode.shipment => Icons.local_shipping_outlined,
      };
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

class _ChipsRow<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final IconData Function(T) iconOf;
  final ValueChanged<T> onChanged;
  const _ChipsRow({
    required this.values, required this.selected,
    required this.labelOf, required this.iconOf, required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Wrap(spacing: 6, runSpacing: 6, children: [
      for (final v in values)
        InkWell(
          onTap: () => onChanged(v),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: v == selected
                  ? sem.brandSurface
                  : const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: v == selected
                      ? sem.brand.withValues(alpha: 0.4)
                      : sem.borderSubtle),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(iconOf(v), size: 14,
                  color: v == selected
                      ? sem.brandText
                      : const Color(0xFF6B7280)),
              const SizedBox(width: 6),
              Text(labelOf(v),
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: v == selected
                          ? FontWeight.w700 : FontWeight.w500,
                      color: v == selected
                          ? sem.brandText
                          : const Color(0xFF111827))),
            ]),
          ),
        ),
    ]);
  }
}

// ─── Suivi paiement à la validation (hotfix_065) ───────────────────────────
//
// 3 modes mutuellement exclusifs :
//   • keepCurrent : ne touche pas au paiement existant (default).
//   • addPartial  : ajoute un nouveau versement au total déjà encaissé.
//   • markFull    : marque la commande comme totalement encaissée
//                   (amount_paid = total, payment_status = paid).
enum _ProcessingPaymentChoice { keepCurrent, addPartial, markFull }

class _ProcessingPaymentRow extends StatelessWidget {
  final _ProcessingPaymentChoice selected;
  final ValueChanged<_ProcessingPaymentChoice> onChanged;
  final bool                                  hasAcompte;
  const _ProcessingPaymentRow({
    required this.selected,
    required this.onChanged,
    required this.hasAcompte,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6, runSpacing: 6,
      children: [
        _ProcChip(
          label: hasAcompte ? 'Pas de versement' : 'Aucun',
          icon:  Icons.money_off_rounded,
          active: selected == _ProcessingPaymentChoice.keepCurrent,
          onTap: () => onChanged(_ProcessingPaymentChoice.keepCurrent),
        ),
        _ProcChip(
          label: 'Acompte / Versement',
          icon:  Icons.payments_outlined,
          active: selected == _ProcessingPaymentChoice.addPartial,
          onTap: () => onChanged(_ProcessingPaymentChoice.addPartial),
        ),
        _ProcChip(
          label: 'Tout encaissé',
          icon:  Icons.check_circle_rounded,
          active: selected == _ProcessingPaymentChoice.markFull,
          onTap: () => onChanged(_ProcessingPaymentChoice.markFull),
        ),
      ],
    );
  }
}

class _ProcChip extends StatelessWidget {
  final String       label;
  final IconData     icon;
  final bool         active;
  final VoidCallback onTap;
  const _ProcChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active ? sem.brandSurface : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: active
                  ? sem.brand.withValues(alpha: 0.4)
                  : sem.borderSubtle),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
              size: 14,
              color: active ? sem.brandText : const Color(0xFF6B7280)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? sem.brandText : const Color(0xFF111827))),
        ]),
      ),
    );
  }
}

String _fmtMoney(double amount) {
  final fmt = NumberFormat('#,###', 'fr_FR');
  return '${fmt.format(amount)} ${CurrencyFormatter.currentSymbol}';
}
