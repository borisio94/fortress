import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import 'arrival_widgets.dart';

// ═════════════════════════════════════════════════════════════════════════════
// Création d'un produit DEPUIS la saisie d'arrivage.
//
// Un arrivage mélange presque toujours du réassort et de la nouveauté : le
// conteneur contient 10 montres déjà au catalogue et 3 modèles jamais vendus.
// Sans ce raccourci, il fallait sortir de la saisie, créer la fiche produit
// complète, revenir, et retrouver sa place dans la liste — au risque de
// perdre les quantités déjà pointées.
//
// La fiche créée ici est VOLONTAIREMENT minimale (nom, référence, prix, qté).
// Le reste — catégorie, images, variantes, description — se complète plus
// tard dans la fiche produit : au moment où l'on décharge un carton, on n'a
// ni le temps ni les photos.
//
// Le stock N'EST PAS écrit ici : la quantité saisie devient une ligne de
// l'arrivage, et c'est `ArrivalService` qui l'entre en stock avec sa part de
// frais de lot. Sans ça, la quantité serait comptée deux fois.
// ═════════════════════════════════════════════════════════════════════════════

/// Produit à créer, tel que saisi dans la feuille d'arrivage. Reste un
/// brouillon tant que l'arrivage n'est pas validé : on peut le corriger ou
/// le retirer sans avoir pollué le catalogue.
class NewProductDraft {
  /// Identifiant local du brouillon — sert de clé de ligne dans la saisie,
  /// avant que le produit ait un vrai `prod_…`.
  final String key;
  String name;
  String? sku;
  double priceBuy;
  double priceSell;
  int quantity;

  NewProductDraft({
    required this.key,
    required this.name,
    this.sku,
    this.priceBuy = 0,
    this.priceSell = 0,
    this.quantity = 1,
  });
}

/// Ouvre la saisie d'un nouveau produit. [initial] pré-remplit le formulaire
/// (modification d'un brouillon déjà posé) ; [initialName] amorce le nom
/// quand la création part d'une recherche restée sans résultat.
Future<NewProductDraft?> showNewProductDraftSheet(
  BuildContext context, {
  NewProductDraft? initial,
  String? initialName,
}) {
  return showAdaptiveFormSheet<NewProductDraft>(
    context: context,
    builder: (_) => _NewProductDraftForm(
      initial: initial,
      initialName: initialName,
    ),
  );
}

class _NewProductDraftForm extends StatefulWidget {
  final NewProductDraft? initial;
  final String? initialName;
  const _NewProductDraftForm({this.initial, this.initialName});

  @override
  State<_NewProductDraftForm> createState() => _NewProductDraftFormState();
}

class _NewProductDraftFormState extends State<_NewProductDraftForm> {
  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _priceBuy;
  late final TextEditingController _priceSell;
  late final TextEditingController _qty;

  @override
  void initState() {
    super.initState();
    final d = widget.initial;
    _name  = TextEditingController(text: d?.name ?? widget.initialName ?? '');
    _sku   = TextEditingController(text: d?.sku ?? '');
    _priceBuy = TextEditingController(
        text: (d?.priceBuy ?? 0) > 0 ? d!.priceBuy.toStringAsFixed(0) : '');
    _priceSell = TextEditingController(
        text: (d?.priceSell ?? 0) > 0 ? d!.priceSell.toStringAsFixed(0) : '');
    _qty = TextEditingController(text: '${d?.quantity ?? 1}');
  }

  @override
  void dispose() {
    _name.dispose();
    _sku.dispose();
    _priceBuy.dispose();
    _priceSell.dispose();
    _qty.dispose();
    super.dispose();
  }

  double _money(TextEditingController c) {
    final v = double.tryParse(c.text.trim().replaceAll(',', '.')) ?? 0;
    return v.isFinite && v > 0 ? v : 0;
  }

  bool get _valid => _name.text.trim().isNotEmpty && _quantity > 0;

  int get _quantity {
    final v = int.tryParse(_qty.text.trim()) ?? 0;
    return v > 0 ? v : 0;
  }

  void _submit() {
    if (!_valid) return;
    final now = DateTime.now().microsecondsSinceEpoch;
    Navigator.of(context).pop(NewProductDraft(
      key:       widget.initial?.key ?? 'draft_$now',
      name:      _name.text.trim(),
      sku:       _sku.text.trim().isEmpty ? null : _sku.text.trim(),
      priceBuy:  _money(_priceBuy),
      priceSell: _money(_priceSell),
      quantity:  _quantity,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.initial != null;
    return AdaptiveFormFrame(
      title: editing ? 'Modifier le produit' : 'Nouveau produit',
      subtitle: 'Créé avec l\'arrivage — la fiche complète se remplit ensuite',
      icon: Icons.add_box_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label('Nom du produit'),
          PlainField(
            controller: _name,
            hint: 'Ex. Olevs 9925',
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _label('Référence / SKU', optional: true),
          PlainField(
            controller: _sku,
            hint: 'Ex. OL9925GDBKBRL',
            onChanged: () {},
          ),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              _label('Prix d\'achat'),
              PlainField(
                controller: _priceBuy,
                hint: '0',
                numeric: true,
                onChanged: () {},
              ),
            ])),
            const SizedBox(width: 12),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              _label('Prix de vente'),
              PlainField(
                controller: _priceSell,
                hint: '0',
                numeric: true,
                onChanged: () {},
              ),
            ])),
          ]),
          const SizedBox(height: 12),
          _label('Quantité reçue'),
          PlainField(
            controller: _qty,
            hint: '1',
            numeric: true,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 8),
          Text(
              'Le prix d\'achat reste modifiable dans la ligne d\'arrivage, '
              'et les frais du lot s\'y ajouteront.',
              style: AppTextStyles.micro.copyWith(color: AppColors.textHint)),
        ]),
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: SizedBox(width: double.infinity, height: 46,
          child: ElevatedButton.icon(
            onPressed: _valid ? _submit : null,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: Text(editing ? 'Enregistrer' : 'Ajouter à l\'arrivage'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryFill,
              foregroundColor: Colors.white,
              elevation: 0,
              disabledBackgroundColor: AppColors.divider,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10))),
          ),
        ),
      ),
    );
  }

  Widget _label(String text, {bool optional = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(children: [
      Text(text, style: AppTextStyles.micro.copyWith(
          fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
      if (optional) ...[
        const SizedBox(width: 6),
        Text('· facultatif',
            style: AppTextStyles.micro.copyWith(color: AppColors.textHint)),
      ],
    ]),
  );
}

/// Carte d'un produit à créer, dans la liste de saisie de l'arrivage.
/// Se distingue des produits du catalogue par le badge « Nouveau » : sans ce
/// repère, on ne sait plus, au moment de valider, ce qui va être créé.
class NewProductDraftCard extends StatelessWidget {
  final NewProductDraft draft;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final ValueChanged<int> onQuantity;

  const NewProductDraftCard({
    super.key,
    required this.draft,
    required this.onEdit,
    required this.onRemove,
    required this.onQuantity,
  });

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.45)),
      ),
      child: Column(children: [
        Row(children: [
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(draft.name,
                  style: AppTextStyles.bodySmBold,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.primaryFill,
                  borderRadius: BorderRadius.circular(4)),
                child: Text('Nouveau',
                    style: AppTextStyles.micro.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 2),
            Text(
                draft.sku == null || draft.sku!.isEmpty
                    ? 'Sera créé au catalogue'
                    : '${draft.sku} · sera créé au catalogue',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.micro.copyWith(color: AppColors.textHint)),
          ])),
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 16),
            tooltip: 'Modifier',
            color: AppColors.primary,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30)),
          IconButton(
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded, size: 16),
            tooltip: 'Retirer de l\'arrivage',
            color: AppColors.error,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: Text(
              'Prix d\'achat ${draft.priceBuy.toStringAsFixed(0)}'
              '${draft.priceSell > 0
                  ? ' · vente ${draft.priceSell.toStringAsFixed(0)}' : ''}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.micro
                  .copyWith(color: AppColors.textSecondary))),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: sem.borderSubtle)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                onPressed: draft.quantity > 1
                    ? () => onQuantity(draft.quantity - 1) : null,
                icon: const Icon(Icons.remove_circle_outline, size: 18),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                color: AppColors.primary),
              SizedBox(width: 26, child: Center(child: Text('${draft.quantity}',
                  style: AppTextStyles.label
                      .copyWith(fontWeight: FontWeight.w700)))),
              IconButton(
                onPressed: () => onQuantity(draft.quantity + 1),
                icon: const Icon(Icons.add_circle_outline, size: 18),
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 30, minHeight: 30),
                color: AppColors.primary),
            ]),
          ),
        ]),
      ]),
    );
  }
}
