import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/approval_closure.dart';
import '../../domain/entities/sale.dart';
import '../../domain/entities/sale_item.dart';
import 'order_completion_sheet.dart' show CollectedBy;

/// Résultat du sheet de clôture d'une tournée « à choisir sur place ».
///
/// La clôture est une VRAIE finalisation de vente : elle réconcilie le stock
/// réservé ET encaisse le client. Sans le volet encaissement, la commande
/// partait en `completed` avec `amount_paid = 0` / `payment_status = unpaid`
/// (bug rapporté : « terminée mais reste non payée »).
class ApprovalClosureResult {
  /// Quantité GARDÉE (vendue) par article — clé = `SaleItem.productId`.
  final Map<String, int> kept;

  /// Montant TOTAL encaissé du client (cumulé, acompte inclus) une fois la
  /// tournée close. `null` = ne pas toucher au paiement (cas « rien gardé »
  /// → la commande est annulée, il n'y a rien à encaisser).
  final double? amountPaidTotal;

  /// Qui a physiquement encaissé (pilote les écritures du livre partenaire,
  /// exactement comme la finalisation classique).
  final CollectedBy collectedBy;

  const ApprovalClosureResult({
    required this.kept,
    required this.amountPaidTotal,
    required this.collectedBy,
  });
}

/// Ouvre le sheet de clôture d'une tournée « à choisir sur place ».
///
/// Pour chaque article réservé, l'opérateur saisit la quantité GARDÉE par le
/// client (stepper borné à `[0, réservé]`), puis le montant encaissé. Retourne
/// un [ApprovalClosureResult] à passer à
/// `SaleLocalDatasource.closeApprovalOrder`, ou `null` si annulé.
Future<ApprovalClosureResult?> showApprovalClosureSheet(
  BuildContext context, {
  required Sale order,
}) {
  return showAdaptiveFormSheet<ApprovalClosureResult>(
    context: context,
    builder: (_) => _ApprovalClosureSheet(order: order),
  );
}

class _ApprovalClosureSheet extends StatefulWidget {
  final Sale order;
  const _ApprovalClosureSheet({required this.order});

  @override
  State<_ApprovalClosureSheet> createState() => _ApprovalClosureSheetState();
}

class _ApprovalClosureSheetState extends State<_ApprovalClosureSheet> {
  // Quantité gardée (vendue) par article. Par défaut : tout est gardé.
  late final Map<String, int> _kept;

  final _amountCtrl = TextEditingController();
  /// Vrai dès que l'opérateur a modifié le champ montant à la main : on cesse
  /// alors de le re-préremplir quand les quantités gardées changent (sinon sa
  /// saisie serait écrasée à chaque tap sur un stepper).
  bool _amountTouched = false;
  late CollectedBy _collectedBy;
  String? _error;

  /// Livraison par un dépôt partenaire → l'argent peut avoir été encaissé par
  /// le partenaire (créance à suivre dans le livre partenaire).
  bool get _isPartnerDelivery =>
      widget.order.deliveryMode == DeliveryMode.partner &&
      (widget.order.deliveryLocationId ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    _kept = {for (final i in widget.order.items) i.productId: i.quantity};
    // Défaut cohérent avec la finalisation classique : si un partenaire livre,
    // c'est lui qui encaisse sur place (le plus fréquent en tournée).
    _collectedBy =
        _isPartnerDelivery ? CollectedBy.partnerNotRemitted : CollectedBy.boutique;
    _amountCtrl.text = _due > 0 ? _due.toStringAsFixed(0) : '';
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  /// Quantité réservée par article (clé = productId) — base de la borne.
  Map<String, int> get _reserved =>
      {for (final i in widget.order.items) i.productId: i.quantity};

  /// Articles effectivement gardés, quantité ajustée (base de la vente finale).
  List<SaleItem> get _keptItems => [
        for (final i in widget.order.items)
          if ((_kept[i.productId] ?? 0) > 0)
            i.copyWith(quantity: _kept[i.productId]!)
      ];

  /// Montant réellement facturé au client après réconciliation : articles
  /// gardés + livraison + frais (même formule que [Sale.total]).
  double get _keptTotal =>
      _keptItems.isEmpty ? 0 : widget.order.copyWith(items: _keptItems).total;

  double get _paidBefore => widget.order.amountPaid;

  /// Reste à encaisser sur la vente finale.
  double get _due => (_keptTotal - _paidBefore).clamp(0, double.infinity);

  /// Rien gardé → la tournée revient entière : la commande sera annulée et
  /// tout le stock remis en rayon (aucun encaissement).
  bool get _nothingKept => _keptItems.isEmpty;

  void _syncAmountField() {
    if (_amountTouched) return;
    _amountCtrl.text = _due > 0 ? _due.toStringAsFixed(0) : '';
  }

  void _inc(String productId, int max) {
    final cur = _kept[productId] ?? 0;
    if (cur >= max) return;
    setState(() {
      _kept[productId] = cur + 1;
      _error = null;
      _syncAmountField();
    });
  }

  void _dec(String productId) {
    final cur = _kept[productId] ?? 0;
    if (cur <= 0) return;
    setState(() {
      _kept[productId] = cur - 1;
      _error = null;
      _syncAmountField();
    });
  }

  void _submit() {
    // Rien gardé : pas d'encaissement, la commande part en annulée.
    if (_nothingKept) {
      Navigator.of(context).pop(ApprovalClosureResult(
        kept: Map<String, int>.from(_kept),
        amountPaidTotal: null,
        collectedBy: CollectedBy.boutique,
      ));
      return;
    }

    double paidTotal;
    if (_collectedBy == CollectedBy.partnerNotRemitted) {
      // Le partenaire a encaissé POUR la boutique : côté client la vente est
      // soldée (pas de créance client) ; la créance est celle du partenaire,
      // matérialisée par le livre partenaire (`saleCollected`).
      paidTotal = _keptTotal;
    } else {
      final raw = _amountCtrl.text.trim();
      final entered =
          raw.isEmpty ? 0.0 : double.tryParse(raw.replaceAll(',', '.')) ?? -1;
      if (entered < 0) {
        setState(() => _error = 'Montant invalide');
        return;
      }
      if (entered > _due) {
        setState(() => _error =
            'Maximum ${CurrencyFormatter.format(_due)} (reste à payer)');
        return;
      }
      paidTotal = (_paidBefore + entered).clamp(0, _keptTotal).toDouble();
    }

    Navigator.of(context).pop(ApprovalClosureResult(
      kept: Map<String, int>.from(_kept),
      amountPaidTotal: paidTotal,
      collectedBy: _collectedBy,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    // Réconciliation pure : total vendu vs total remis en stock.
    final recon = ApprovalClosure.reconcile(reserved: _reserved, kept: _kept);

    return AdaptiveFormFrame(
      title: 'Clôturer la tournée',
      subtitle: widget.order.clientName,
      icon: Icons.fact_check_outlined,
      iconColor: AppColors.primary,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Indique pour chaque article la quantité GARDÉE par le '
              'client. Le reste est automatiquement remis en stock.',
              style: AppTextStyles.captionHint
                  .copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            for (final item in widget.order.items)
              _ApprovalItemRow(
                name: item.variantName != null && item.variantName!.isNotEmpty
                    ? '${item.productName} · ${item.variantName}'
                    : item.productName,
                reserved: item.quantity,
                kept: _kept[item.productId] ?? 0,
                onDec: () => _dec(item.productId),
                onInc: () => _inc(item.productId, item.quantity),
              ),

            // ── Récapitulatif gardé / retourné ────────────────────────────
            const SizedBox(height: 4),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: sem.brandSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: sem.brand.withValues(alpha: 0.25)),
              ),
              child: Row(children: [
                Expanded(
                  child: _RecapCell(
                    label: 'Gardé (vendu)',
                    value: recon.totalKept,
                    color: sem.brandText,
                  ),
                ),
                Container(width: 1, height: 28, color: sem.borderSubtle),
                Expanded(
                  child: _RecapCell(
                    label: 'Retourné (stock)',
                    value: recon.totalReturned,
                    color: AppColors.textSecondary,
                  ),
                ),
              ]),
            ),

            // ── Encaissement ──────────────────────────────────────────────
            // La clôture FINALISE la vente : sans cette étape la commande
            // arrivait en « terminée / non payée » sans moyen évident de
            // l'encaisser.
            if (!_nothingKept) ...[
              const SizedBox(height: 16),
              Text('ENCAISSEMENT',
                  style: AppTextStyles.captionBold.copyWith(
                      letterSpacing: 0.5, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              _amountRow('Montant de la vente', _keptTotal, bold: true),
              if (_paidBefore > 0)
                _amountRow('Déjà encaissé', _paidBefore),
              _amountRow('Reste à payer', _due,
                  color: _due > 0 ? AppColors.warning : AppColors.secondary,
                  bold: true),

              // Qui a encaissé ? — uniquement si un partenaire livre (sinon
              // c'est forcément la boutique).
              if (_isPartnerDelivery) ...[
                const SizedBox(height: 12),
                Text('Qui a encaissé le client ?',
                    style: AppTextStyles.captionBold
                        .copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: _ChoiceChipBtn(
                      label: 'La boutique',
                      selected: _collectedBy == CollectedBy.boutique,
                      onTap: () => setState(() {
                        _collectedBy = CollectedBy.boutique;
                        _error = null;
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ChoiceChipBtn(
                      label: 'Le partenaire',
                      selected:
                          _collectedBy == CollectedBy.partnerNotRemitted,
                      onTap: () => setState(() {
                        _collectedBy = CollectedBy.partnerNotRemitted;
                        _error = null;
                      }),
                    ),
                  ),
                ]),
              ],

              const SizedBox(height: 10),
              if (_collectedBy == CollectedBy.partnerNotRemitted)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.info.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppColors.info.withValues(alpha: 0.3),
                        width: 0.5),
                  ),
                  child: Row(children: [
                    const Icon(Icons.account_balance_wallet_outlined,
                        size: 14, color: AppColors.info),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Le partenaire a encaissé '
                        '${CurrencyFormatter.format(_due)} : la vente est '
                        'soldée côté client, le versement reste à recevoir.',
                        style: AppTextStyles.captionHint
                            .copyWith(color: AppColors.info),
                      ),
                    ),
                  ]),
                )
              else ...[
                Text('Montant encaissé maintenant',
                    style: AppTextStyles.captionBold.copyWith(
                        letterSpacing: 0.5, color: AppColors.textSecondary)),
                const SizedBox(height: 6),
                TextField(
                  controller: _amountCtrl,
                  enabled: _due > 0,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: false),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onChanged: (_) => setState(() {
                    _amountTouched = true;
                    _error = null;
                  }),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: '0',
                    suffixText: CurrencyFormatter.currentSymbol,
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.inputFill,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: sem.borderSubtle)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: sem.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                  style: AppTextStyles.title,
                ),
                const SizedBox(height: 6),
                Text(
                  'Laisse le montant complet si le client a tout payé. '
                  'Un montant inférieur laisse une créance client.',
                  style: AppTextStyles.captionHint
                      .copyWith(color: AppColors.textSecondary),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: AppTextStyles.captionHint
                        .copyWith(color: AppColors.error)),
              ],
            ] else ...[
              const SizedBox(height: 12),
              Text(
                'Aucun article gardé : la commande sera annulée et tout le '
                'stock remis en rayon.',
                style: AppTextStyles.captionHint
                    .copyWith(color: AppColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
        child: AppPrimaryButton(
          label: _nothingKept
              ? 'Tout remettre en stock'
              : 'Valider et encaisser',
          icon: _nothingKept
              ? Icons.undo_rounded
              : Icons.check_circle_outline_rounded,
          color: _nothingKept ? AppColors.warning : AppColors.primary,
          onTap: _submit,
        ),
      ),
    );
  }

  /// Ligne « libellé …… montant » du récap d'encaissement.
  Widget _amountRow(String label, double value,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: AppTextStyles.bodySm
                  .copyWith(color: AppColors.textSecondary)),
        ),
        Text(CurrencyFormatter.format(value),
            style: AppTextStyles.body.copyWith(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: color ?? AppColors.onSurface)),
      ]),
    );
  }
}

/// Bouton de choix binaire « qui a encaissé ».
class _ChoiceChipBtn extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceChipBtn({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? sem.brandSurface : AppColors.inputFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? AppColors.primary : sem.borderSubtle,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(
            selected
                ? Icons.radio_button_checked_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 16,
            color: selected ? AppColors.primary : AppColors.textHint,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.bodySm.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? AppColors.primary
                        : AppColors.onSurface)),
          ),
        ]),
      ),
    );
  }
}

/// Ligne article : nom + quantité réservée + stepper de la quantité gardée.
class _ApprovalItemRow extends StatelessWidget {
  final String name;
  final int reserved;
  final int kept;
  final VoidCallback onDec;
  final VoidCallback onInc;
  const _ApprovalItemRow({
    required this.name,
    required this.reserved,
    required this.kept,
    required this.onDec,
    required this.onInc,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.inputFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurface)),
              const SizedBox(height: 2),
              Text('Réservé : $reserved',
                  style: AppTextStyles.captionHint
                      .copyWith(color: AppColors.textSecondary)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _StepBtn(icon: Icons.remove_rounded, onTap: onDec),
        SizedBox(
          width: 34,
          child: Text('$kept',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyBold.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.onSurface)),
        ),
        _StepBtn(icon: Icons.add_rounded, onTap: onInc),
      ]),
    );
  }
}

/// Bouton − / + du stepper.
class _StepBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: sem.borderSubtle),
          ),
          child: Icon(icon, size: 18, color: AppColors.primary),
        ),
      ),
    );
  }
}

/// Cellule du récapitulatif bas (libellé + total).
class _RecapCell extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _RecapCell({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$value',
            style: AppTextStyles.subtitleBold
                .copyWith(fontWeight: FontWeight.w800, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: AppTextStyles.captionHint
                .copyWith(color: AppColors.textSecondary)),
      ],
    );
  }
}
