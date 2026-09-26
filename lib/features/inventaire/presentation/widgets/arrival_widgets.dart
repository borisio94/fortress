import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/services/arrival_costing_service.dart';
import '../../../../core/utils/currency_formatter.dart';

// ═══════════════════════════════════════════════════════════════════════════
// Briques de saisie d'un arrivage, partagées par l'inventaire (saisie) et la
// page historique (validation d'un brouillon fournisseur). Elles vivaient
// dans la page Arrivages ; les sortir évite d'en avoir deux versions qui
// divergent au premier correctif.
// ═══════════════════════════════════════════════════════════════════════════

class FeeDraft {
  final TextEditingController label;
  final TextEditingController amount;
  FeeDraft({String label = '', double amount = 0})
      : label  = TextEditingController(text: label),
        amount = TextEditingController(
            text: amount > 0 ? amount.toStringAsFixed(0) : '');
  void dispose() { label.dispose(); amount.dispose(); }
}

// ═══ Choix du mode ══════════════════════════════════════════════════════════

/// Deux natures de bon, qui ne font pas la même chose :
///   * arrivage        → la marchandise entre, avec son coût ;
///   * frais seuls     → elle est déjà entrée, seul le coût est corrigé.
/// Rendu COMPACT (une seule ligne de 34 px) : sur un écran peu haut, la
/// version à deux lignes mangeait ~50 px au-dessus de la liste de produits,
/// qui n'avait plus qu'une carte et demie de hauteur utile. L'explication de
/// chaque mode passe en infobulle plutôt qu'en sous-titre permanent.
class ArrivalModeSelector extends StatelessWidget {
  final bool costOnly;
  final ValueChanged<bool> onChanged;
  const ArrivalModeSelector(
      {super.key, required this.costOnly, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: _seg(context,
        selected: !costOnly,
        icon: Icons.inventory_2_rounded,
        label: 'Arrivage',
        tooltip: 'La marchandise entre en stock',
        onTap: () => onChanged(false))),
    const SizedBox(width: 6),
    Expanded(child: _seg(context,
        selected: costOnly,
        icon: Icons.receipt_long_rounded,
        label: 'Frais seuls',
        tooltip: 'Stock déjà entré',
        onTap: () => onChanged(true))),
  ]);

  Widget _seg(BuildContext context, {
    required bool selected,
    required IconData icon,
    required String label,
    required String tooltip,
    required VoidCallback onTap,
  }) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.primarySurface : AppColors.surface,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
              color: selected
                  ? AppColors.primary
                  : Theme.of(context).semantic.borderSubtle,
              width: selected ? 1.5 : 1),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 15,
              color: selected ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 6),
          Flexible(child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySmBold.copyWith(
                  color: selected ? AppColors.primary : null))),
        ]),
      ),
    ),
  );
}

/// Ajustement du nombre de pièces qui se partagent les frais. Pré-rempli
/// avec le stock, modifiable : le lot d'origine peut être plus grand si des
/// pièces sont déjà parties.
class PiecesStepper extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const PiecesStepper({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Text('Pièces qui se partagent les frais',
        style: AppTextStyles.micro.copyWith(color: AppColors.textSecondary))),
    IconButton(
      onPressed: value > 1 ? () => onChanged(value - 1) : null,
      icon: const Icon(Icons.remove_circle_outline, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      color: AppColors.primary),
    SizedBox(width: 30, child: Center(child: Text('$value',
        style: AppTextStyles.label.copyWith(fontWeight: FontWeight.w700)))),
    IconButton(
      onPressed: () => onChanged(value + 1),
      icon: const Icon(Icons.add_circle_outline, size: 18),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      color: AppColors.primary),
  ]);
}

// ═══ Frais du lot ═══════════════════════════════════════════════════════════

/// Éditeur des frais qui portent sur le LOT ENTIER (transport, douane…).
/// Ils sont répartis à parts égales sur chaque pièce reçue — c'est ce qui
/// permet d'enregistrer un arrivage multi-produits payé en un seul bloc.
/// REPLIABLE : la plupart des arrivages n'ont aucun frais de lot, et le bloc
/// déplié (titre + phrase d'explication + lignes) coûtait ~85 px pris sur la
/// liste de produits. Fermé, il tient sur une ligne et rappelle le total
/// saisi ; il s'ouvre au clic, et d'office dès qu'un frais existe.
class LotFeesEditor extends StatefulWidget {
  final List<FeeDraft> fees;
  final VoidCallback onChanged;

  /// Widget posé À GAUCHE de l'en-tête, sur la même ligne — la feuille
  /// d'arrivage y met le sélecteur de date, ce qui économise une ligne
  /// entière au-dessus de la liste de produits.
  ///
  /// Quand il est fourni, l'en-tête devient une carte autonome (pour tenir
  /// côte à côte avec le `leading`) et les frais saisis s'affichent dans un
  /// panneau pleine largeur en dessous. Sans lui, le rendu d'origine — un
  /// seul bloc — est conservé : `reception_page` l'utilise ainsi, en bout
  /// de liste.
  final Widget? leading;

  const LotFeesEditor({super.key, required this.fees, required this.onChanged,
      this.leading});

  @override
  State<LotFeesEditor> createState() => _LotFeesEditorState();
}

class _LotFeesEditorState extends State<LotFeesEditor> {
  late bool _open = widget.fees.isNotEmpty;

  double get _total => widget.fees.fold(0.0, (s, f) {
    final v = double.tryParse(f.amount.text.trim().replaceAll(',', '.')) ?? 0;
    return s + (v.isFinite && v > 0 ? v : 0);
  });

  void _add() {
    widget.fees.add(FeeDraft());
    setState(() => _open = true);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    // Côte à côte avec un `leading` : deux cartes de même hauteur sur une
    // ligne, les frais saisis en panneau séparé dessous.
    if (widget.leading != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Column(children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: widget.leading!),
                const SizedBox(width: 8),
                Expanded(child: _headerCard(context, compact: true)),
              ],
            ),
          ),
          if (_open) ...[
            const SizedBox(height: 6),
            _feesPanel(context),
          ],
        ]),
      );
    }

    // Rendu d'origine : un seul bloc, en-tête et frais réunis.
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      padding: EdgeInsets.fromLTRB(12, 4, 4, _open ? 10 : 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _header(context),
        if (_open) ...[
          Padding(
            padding: const EdgeInsets.only(right: 8, bottom: 2),
            child: Text(_hint,
                style: AppTextStyles.micro.copyWith(color: AppColors.textHint)),
          ),
          if (widget.fees.isNotEmpty) const SizedBox(height: 8),
          ..._feeRows(const EdgeInsets.only(bottom: 8, right: 4)),
        ],
      ]),
    );
  }

  static const String _hint =
      'Transport, douane, manutention… répartis à parts égales sur '
      'chaque pièce reçue.';

  /// En-tête nu (rendu d'origine, déjà à l'intérieur d'un bloc bordé).
  Widget _header(BuildContext context) => InkWell(
    onTap: () => setState(() => _open = !_open),
    borderRadius: BorderRadius.circular(8),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(Icons.local_shipping_rounded, size: 15, color: AppColors.primary),
        const SizedBox(width: 8),
        const Text('Frais du lot', style: AppTextStyles.bodySmBold),
        if (_total > 0) ...[
          const SizedBox(width: 8),
          Text(CurrencyFormatter.format(_total),
              style: AppTextStyles.microBold
                  .copyWith(color: AppColors.primary)),
        ],
        const Spacer(),
        TextButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add_rounded, size: 14),
          label: Text('Ajouter', style: AppTextStyles.micro
              .copyWith(color: AppColors.primary)),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        ),
        Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            size: 18, color: AppColors.textSecondary),
        const SizedBox(width: 4),
      ]),
    ),
  );

  /// En-tête sous forme de carte autonome, pour tenir à côté du `leading`.
  /// Le libellé « Ajouter » se réduit à un « + » : à demi-largeur, il aurait
  /// poussé le titre à l'ellipse.
  Widget _headerCard(BuildContext context, {bool compact = false}) => InkWell(
    onTap: () => setState(() => _open = !_open),
    borderRadius: BorderRadius.circular(8),
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
      child: Row(children: [
        Icon(Icons.local_shipping_rounded, size: 14, color: AppColors.primary),
        const SizedBox(width: 8),
        const Flexible(child: Text('Frais du lot',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmBold)),
        if (_total > 0) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(CurrencyFormatter.format(_total),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.microBold
                  .copyWith(color: AppColors.primary))),
        ],
        const Spacer(),
        IconButton(
          onPressed: _add,
          icon: const Icon(Icons.add_rounded, size: 16),
          tooltip: 'Ajouter un frais',
          color: AppColors.primary,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26)),
        Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            size: 16, color: AppColors.textHint),
        const SizedBox(width: 2),
      ]),
    ),
  );

  /// Panneau des frais saisis, pleine largeur sous la ligne date + en-tête.
  Widget _feesPanel(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_hint,
          style: AppTextStyles.micro.copyWith(color: AppColors.textHint)),
      if (widget.fees.isNotEmpty) const SizedBox(height: 8),
      ..._feeRows(const EdgeInsets.only(bottom: 8)),
    ]),
  );

  List<Widget> _feeRows(EdgeInsets padding) {
    final fees = widget.fees;
    return List.generate(fees.length, (i) => Padding(
      padding: padding,
      child: Row(children: [
        Expanded(flex: 3, child: PlainField(
          controller: fees[i].label,
          hint: 'Libellé (transport…)',
          onChanged: widget.onChanged)),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: PlainField(
          controller: fees[i].amount,
          hint: 'Montant',
          numeric: true,
          onChanged: () { setState(() {}); widget.onChanged(); })),
        IconButton(
          onPressed: () {
            fees[i].dispose();
            fees.removeAt(i);
            setState(() {});
            widget.onChanged();
          },
          icon: const Icon(Icons.close_rounded, size: 16),
          color: AppColors.error,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30)),
      ]),
    ));
  }
}

/// Récapitulatif : marchandise, frais, frais par pièce, total du lot.
class LotSummary extends StatelessWidget {
  final ArrivalCosting costing;
  /// Bon de frais seuls : pas de marchandise à totaliser, seule compte la
  /// part de frais que chaque pièce va supporter.
  final bool costOnly;
  const LotSummary({required this.costing, this.costOnly = false});

  @override
  Widget build(BuildContext context) {
    if (costing.totalPieces == 0 ||
        (costing.goodsTotal <= 0 && costing.feesTotal <= 0)) {
      return const SizedBox.shrink();
    }
    if (costOnly) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.primarySurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.25))),
        child: Column(children: [
          _row('Frais à imputer', CurrencyFormatter.format(costing.feesTotal)),
          const SizedBox(height: 4),
          _row('Réparti sur', '${costing.totalPieces} pièce'
              '${costing.totalPieces > 1 ? 's' : ''}'),
          const Divider(height: 14),
          _row('Prix d\'achat',
              '+${CurrencyFormatter.format(costing.feePerPiece)} / pièce',
              bold: true),
        ]),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25))),
      child: Column(children: [
        _row('Marchandise (${costing.totalPieces} pièce'
            '${costing.totalPieces > 1 ? 's' : ''})',
            CurrencyFormatter.format(costing.goodsTotal)),
        if (costing.feesTotal > 0) ...[
          const SizedBox(height: 4),
          _row('Frais du lot', CurrencyFormatter.format(costing.feesTotal)),
          const SizedBox(height: 4),
          _row('Frais par pièce',
              CurrencyFormatter.format(costing.feePerPiece), accent: true),
        ],
        const Divider(height: 14),
        _row('Total du lot', CurrencyFormatter.format(costing.grandTotal),
            bold: true),
      ]),
    );
  }

  static Widget _row(String label, String value,
      {bool bold = false, bool accent = false}) => Row(children: [
    Expanded(child: Text(label,
        style: bold ? AppTextStyles.bodySmBold : AppTextStyles.micro.copyWith(
            color: accent ? AppColors.primary : AppColors.textSecondary))),
    Text(value, style: bold
        ? AppTextStyles.bodySmBold
        : AppTextStyles.microBold.copyWith(
            color: accent ? AppColors.primary : AppColors.textSecondary)),
  ]);
}

/// Champ montant avec libellé — utilisé pour le prix d'achat unitaire.
class MoneyField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final VoidCallback onChanged;
  const MoneyField({required this.label, required this.controller,
    required this.onChanged, this.hint});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        Text(label, style: AppTextStyles.micro
            .copyWith(fontWeight: FontWeight.w600,
                color: AppColors.textSecondary)),
        if (hint != null) ...[
          const SizedBox(width: 6),
          Text('· $hint', style: AppTextStyles.micro
              .copyWith(color: AppColors.textHint)),
        ],
      ]),
      const SizedBox(height: 4),
      PlainField(controller: controller, hint: '0', numeric: true,
          onChanged: onChanged),
    ],
  );
}

class PlainField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool numeric;
  final VoidCallback onChanged;
  const PlainField({required this.controller, required this.hint,
    required this.onChanged, this.numeric = false});

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text,
    style: AppTextStyles.input,
    onChanged: (_) => onChanged(),
    decoration: InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: AppTextStyles.bodySm.copyWith(color: AppColors.textHint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      filled: true,
      fillColor: Theme.of(context).colorScheme.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
    ),
  );
}

// ═══ Widgets réutilisables ══════════════════════════════════════════════════
