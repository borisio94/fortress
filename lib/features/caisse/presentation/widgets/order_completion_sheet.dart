import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/widgets/back_dated_picker.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../bloc/caisse_bloc.dart' show OrderFee;
import '../../../../core/widgets/touch_target.dart';

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

  /// Montant TOTAL réellement encaissé du client après cette clôture
  /// (acompte déjà versé + ce qui est encaissé maintenant). Sert à la VENTE
  /// À CRÉDIT : si < total, le reste devient une créance client
  /// (`payment_status = partial/unpaid`) au lieu d'être effacé.
  ///
  /// `null` = comportement historique : la clôture force « entièrement payé »
  /// (cas partenaire encaisseur, ou commande déjà soldée). N'est renseigné
  /// que lorsque la boutique encaisse une commande pas encore soldée.
  final double? amountPaidTotal;

  const OrderCompletionResult({
    required this.fees,
    required this.collectedBy,
    this.completedAt,
    this.amountPaidTotal,
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
  /// Solde courant du partenaire AVANT cette complétion (signé). > 0 : il
  /// nous doit ; < 0 : on lui doit. Si non null, on affiche un récap
  /// "Solde avant / après" qui rend visible la compensation automatique.
  double? partnerBalanceBefore,
  /// `true` si la commande est déjà entièrement payée à la boutique
  /// (amountPaid >= total). Dans ce cas, le radio "Partenaire a encaissé"
  /// est désactivé et le choix forcé sur `boutique` — impossible que le
  /// partenaire ait encaissé quelque chose si tout a été versé en amont.
  bool orderAlreadyFullyPaid = false,
  /// Total facturé de la commande — sert au récap d'encaissement et au calcul
  /// du reste à crédit (vente à crédit).
  double orderTotal = 0,
  /// Acompte déjà encaissé par la boutique avant la clôture.
  double amountPaidBefore = 0,
  /// `true` uniquement si la commande est LIVRÉE PAR UN PARTENAIRE
  /// (deliveryMode == partner). Sinon (livraison équipe boutique, retrait sur
  /// place…) l'option « Partenaire — pas encore versé » n'a aucun sens : on
  /// masque la section « Qui a encaissé ? » et l'encaissement est forcément
  /// boutique → aucun bandeau bleu « à verser ».
  bool allowPartnerCollected = true,
}) {
  return showFormSheet<OrderCompletionResult>(
    context: context,
    builder: (_) => _OrderCompletionSheet(
      initialFees:        initialFees,
      defaultCollectedBy: (orderAlreadyFullyPaid || !allowPartnerCollected)
          ? CollectedBy.boutique
          : defaultCollectedBy,
      partnerName:        partnerName,
      partnerBalanceBefore: partnerBalanceBefore,
      orderAlreadyFullyPaid: orderAlreadyFullyPaid,
      orderTotal:         orderTotal,
      amountPaidBefore:   amountPaidBefore,
      allowPartnerCollected: allowPartnerCollected,
    ),
  );
}

class _OrderCompletionSheet extends StatefulWidget {
  final List<OrderFee> initialFees;
  final CollectedBy    defaultCollectedBy;
  final String?        partnerName;
  final double?        partnerBalanceBefore;
  final bool           orderAlreadyFullyPaid;
  final double         orderTotal;
  final double         amountPaidBefore;
  final bool           allowPartnerCollected;
  const _OrderCompletionSheet({
    required this.initialFees,
    required this.defaultCollectedBy,
    this.partnerName,
    this.partnerBalanceBefore,
    this.orderAlreadyFullyPaid = false,
    this.orderTotal = 0,
    this.amountPaidBefore = 0,
    this.allowPartnerCollected = true,
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

  /// Montant encaissé du client maintenant (vente à crédit). Pré-rempli au
  /// solde dû ; l'opérateur peut saisir moins → le reste devient une créance.
  final _collectedNow = TextEditingController();

  /// Solde dû avant cette clôture = total − acompte (jamais négatif).
  double get _due =>
      (widget.orderTotal - widget.amountPaidBefore).clamp(0, double.infinity);

  /// `true` si la section « Encaissement du client » est pertinente : la
  /// boutique encaisse (pas le partenaire) ET la commande n'est pas déjà
  /// soldée ET il reste quelque chose à payer.
  bool get _showCollect =>
      _collectedBy == CollectedBy.boutique
      && !widget.orderAlreadyFullyPaid
      && _due > 0;

  /// Montant saisi maintenant (0 si vide/invalide).
  double get _collectedAmount =>
      double.tryParse(_collectedNow.text.trim().replaceAll(',', '.')) ?? 0;

  /// Reste à crédit après cette clôture (≥ 0).
  double get _creditAfter =>
      (_due - _collectedAmount).clamp(0, double.infinity);

  @override
  void initState() {
    super.initState();
    // Sans livraison partenaire, l'encaissement est forcément boutique.
    _collectedBy = widget.allowPartnerCollected
        ? widget.defaultCollectedBy
        : CollectedBy.boutique;
    _completedAt = DateTime.now();
    if (_due > 0) _collectedNow.text = _due.toStringAsFixed(0);
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
    _collectedNow.dispose();
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
      if (amt <= 0 && lbl.isEmpty) continue; // ligne vide → skip
      fees.add(OrderFee(
        id:     r.id,
        label:  lbl.isEmpty ? 'Frais' : lbl,
        amount: amt,
      ));
    }

    // Garde-fou anti-doublon : avertir (sans bloquer) si un libellé revient
    // (ex. deux « Livraison ») → évite de déduire 2× le même frais.
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

    // Vente à crédit : si la boutique encaisse une commande pas encore soldée,
    // on capture le total réellement encaissé (acompte + maintenant). Si <
    // total, le reste devient une créance client. `null` sinon → clôture
    // « entièrement payé » (comportement historique).
    double? amountPaidTotal;
    if (_showCollect) {
      final entered = _collectedAmount;
      if (entered > _due) {
        // Sécurité : ne jamais encaisser plus que le solde dû.
        return;
      }
      amountPaidTotal =
          (widget.amountPaidBefore + entered).clamp(0, widget.orderTotal)
              .toDouble();
    }

    if (!mounted) return;
    Navigator.of(context).pop(OrderCompletionResult(
      fees: fees, collectedBy: _collectedBy,
      completedAt: _completedAt,
      amountPaidTotal: amountPaidTotal));
  }

  /// Section « Encaissement du client » — cœur de la vente à crédit.
  /// Récap (total / déjà encaissé / reste) + champ « encaissé maintenant »
  /// pré-rempli au solde. Si l'opérateur saisit moins, un bandeau indique le
  /// reste qui passe en créance client.
  Widget _buildCollectSection(BuildContext context) {
    final theme = Theme.of(context);
    final sym = CurrencyFormatter.currentSymbol;
    final fmt = NumberFormat('#,###', 'fr_FR');
    final credit = _creditAfter;
    final over = _collectedAmount > _due;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(10),
        border:
            Border.all(color: AppColors.primary.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Encaissement du client',
              style: AppTextStyles.captionBold.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 8),
          _miniRow(theme, 'Total commande', '${fmt.format(widget.orderTotal)} $sym',
              bold: true),
          if (widget.amountPaidBefore > 0)
            _miniRow(theme, 'Déjà encaissé (acompte)',
                '${fmt.format(widget.amountPaidBefore)} $sym'),
          _miniRow(theme, 'Reste à payer', '${fmt.format(_due)} $sym',
              color: AppColors.warning, bold: true),
          const SizedBox(height: 10),
          Text('Encaissé maintenant',
              style: AppTextStyles.captionBold.copyWith(
                  letterSpacing: 0.5,
                  color:
                      theme.colorScheme.onSurface.withValues(alpha: 0.6))),
          const SizedBox(height: 6),
          TextField(
            controller: _collectedNow,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '0',
              suffixText: sym,
              isDense: true,
              filled: true,
              fillColor: AppColors.inputFill,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: theme.semantic.borderSubtle)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: theme.semantic.borderSubtle)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.primary, width: 1.5)),
            ),
            style: AppTextStyles.title,
          ),
          if (over) ...[
            const SizedBox(height: 8),
            Text('Maximum ${fmt.format(_due)} $sym (le reste à payer)',
                style: AppTextStyles.captionHint
                    .copyWith(color: theme.colorScheme.error)),
          ] else if (credit > 0) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.warning.withValues(alpha: 0.3)),
              ),
              child: Row(children: [
                const Icon(Icons.account_balance_wallet_outlined,
                    size: 15, color: AppColors.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                      'Reste à crédit : ${fmt.format(credit)} $sym — '
                      'enregistré comme créance du client, réglable plus tard.',
                      style: AppTextStyles.captionBold.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.85))),
                ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget _miniRow(ThemeData theme, String label, String value,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Expanded(
          child: Text(label,
              style: AppTextStyles.bodySm.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.7))),
        ),
        Text(value,
            style: AppTextStyles.bodySm.copyWith(
                fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
                color: color ?? theme.colorScheme.onSurface)),
      ]),
    );
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
                // Section « Qui a encaissé ? » UNIQUEMENT si la commande est
                // livrée par un partenaire. Sinon (livraison équipe boutique,
                // retrait sur place…) l'encaissement est forcément boutique →
                // pas de choix à faire, pas de bandeau bleu « à verser ».
                if (widget.allowPartnerCollected) ...[
                Text(
                  'Qui a encaissé le client ?',
                  style: AppTextStyles.captionBold.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.55)),
                ),
                const SizedBox(height: 4),
                _CollectedByRadio(
                  value: _collectedBy,
                  partnerName: widget.partnerName,
                  onChanged: (v) => setState(() => _collectedBy = v),
                  lockToBoutique: widget.orderAlreadyFullyPaid,
                ),
                if (widget.orderAlreadyFullyPaid) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.secondary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.secondary
                              .withValues(alpha: 0.3)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.check_circle_rounded,
                          size: 14, color: AppColors.secondary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            'Commande déjà encaissée par la boutique '
                            'avant la livraison. Les frais de livraison '
                            'seront enregistrés comme dette envers '
                            'le partenaire.',
                            style: AppTextStyles.captionBold
                                .copyWith(color: const Color(0xFF065F46))),
                      ),
                    ]),
                  ),
                ],
                // Bandeau récap solde partenaire : visible si le caller a
                // fourni `partnerBalanceBefore` ET que le partenaire a un
                // solde non nul (dette croisée). Rend visible la
                // compensation automatique du partner_ledger : par ex.
                // si on doit 8 000 au partenaire et qu'il encaisse une
                // vente de 30 000, le solde net devient 22 000.
                if (widget.partnerBalanceBefore != null
                    && widget.partnerBalanceBefore!.abs() > 0
                    && _collectedBy == CollectedBy.partnerNotRemitted) ...[
                  const SizedBox(height: 10),
                  _PartnerBalanceHint(
                    balanceBefore: widget.partnerBalanceBefore!,
                  ),
                ],
                ], // fin section « Qui a encaissé ? » (partenaire uniquement)
                // ── Encaissement du client (vente à crédit) ──────────
                // Visible quand la boutique encaisse une commande pas encore
                // soldée. L'opérateur saisit le montant réellement reçu ; le
                // reste devient une créance client (réglable plus tard via le
                // bouton « acompte »).
                if (_showCollect) ...[
                  const SizedBox(height: 16),
                  _buildCollectSection(context),
                ],
                const SizedBox(height: 16),
                // ── Picker date d'encaissement (antidatable) ─────────
                // Permet à un marchand de finaliser une vente passée
                // (numérisation historique). Bornes via pickBackDateTime
                // (firstDate=2020, lastDate=now+1j).
                Text('Date d\'encaissement',
                    style: AppTextStyles.captionBold.copyWith(
                        fontWeight: FontWeight.w800,
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
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: Theme.of(context).semantic.borderSubtle),
                    ),
                    child: Row(children: [
                      Icon(Icons.event_rounded,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_formatCompletedAt(_completedAt),
                            style: AppTextStyles.bodyBold),
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
                  style: AppTextStyles.bodySm.copyWith(
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 12),
                ..._rows.map((r) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(flex: 3, child: TextField(
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
                    Expanded(flex: 2, child: TextField(
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
                        foregroundColor: sem.brand,
                        padding: EdgeInsets.zero),
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
                            fontWeight: FontWeight.w800,
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

class _CollectedByRadio extends StatelessWidget {
  final CollectedBy value;
  final String? partnerName;
  final ValueChanged<CollectedBy> onChanged;
  /// Si `true`, le radio "Partenaire a encaissé" est désactivé visuellement
  /// — impossible que le partenaire ait encaissé si la boutique a déjà
  /// reçu tout le paiement en amont. Empêche un faux saleCollected.
  final bool                      lockToBoutique;
  const _CollectedByRadio({
    required this.value, required this.onChanged, this.partnerName,
    this.lockToBoutique = false,
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
          onTap:    lockToBoutique
              ? null  // désactivé : la commande est déjà entièrement payée
              : () => onChanged(CollectedBy.partnerNotRemitted),
          disabled: lockToBoutique,
        ),
      ],
    );
  }
}

class _RadioRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final bool disabled;
  const _RadioRow({
    required this.label, required this.selected, required this.onTap,
    this.disabled = false,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final textColor = disabled
        ? AppColors.textHint
        : (selected ? sem.brandText : AppColors.onSurface);
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      // La CIBLE est la ligne entière ; le rond de 18 px n'en est que le
      // dessin. Au doigt, la ligne monte à 48 px de haut (lot 2) — elle n'en
      // faisait que 30.
      child: ConstrainedBox(
        constraints: BoxConstraints(
            minHeight: isTouchPlatform ? kMinTouchTarget : 0),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: Row(children: [
            SizedBox(
              width: 18, height: 18,
              child: Radio<bool>(
                value: true, groupValue: selected,
                onChanged: disabled ? null : (_) => onTap?.call(),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                activeColor: sem.brand,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(label,
                style: AppTextStyles.bodySm.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: textColor))),
          ]),
        ),
      ),
    );
  }
}

// ─── Bandeau récap solde partenaire ────────────────────────────────────────
//
// Affiché dans le Sheet C de complétion quand le partenaire a un solde
// non nul AVANT cette vente. Rend visible la compensation automatique
// du partner_ledger : l'opérateur voit que la dette/créance existante
// va être absorbée par le nouveau saleCollected, sans avoir à faire
// l'arithmétique mentalement.
class _PartnerBalanceHint extends StatelessWidget {
  /// Solde signé du partenaire AVANT cette complétion. > 0 = il nous doit
  /// déjà. < 0 = on lui doit (dette créée par des dépenses additionnelles).
  final double balanceBefore;
  const _PartnerBalanceHint({required this.balanceBefore});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDebt = balanceBefore < 0; // on lui doit
    final color = isDebt
        ? AppColors.error
        : AppColors.secondary;
    final bg    = isDebt
        ? AppColors.error.withValues(alpha: 0.12)
        : AppColors.secondary.withValues(alpha: 0.12);
    final label = isDebt
        ? 'Vous lui devez ${CurrencyFormatter.format(balanceBefore.abs())} '
          '— sera déduit du montant qu\'il vous reversera'
        : 'Il vous doit déjà '
          '${CurrencyFormatter.format(balanceBefore)} '
          '— s\'ajoute au montant de cette vente';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        Icon(
            isDebt
                ? Icons.account_balance_wallet_outlined
                : Icons.savings_outlined,
            size: 14, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(label,
              style: AppTextStyles.captionBold.copyWith(
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.85))),
        ),
      ]),
    );
  }
}
