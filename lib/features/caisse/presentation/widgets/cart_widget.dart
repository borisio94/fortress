import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/config/restaurant_mode.dart';
import '../../../restaurant/presentation/widgets/resto_surfaces.dart';
import '../../../../core/i18n/app_localizations.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../bloc/caisse_bloc.dart';
import '../../domain/entities/sale_item.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/country_phone_data.dart';
import '../../../../shared/widgets/product_image_card.dart';
import '../../../crm/domain/entities/client.dart';
import '../../../crm/presentation/pages/clients_page.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/autocomplete_text_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../parametres/data/shop_settings_store.dart';
import 'order_creation_sheet.dart';

class CartWidget extends ConsumerWidget {
  final String shopId;
  final bool   isEcommerce;
  const CartWidget({super.key, required this.shopId,
    this.isEcommerce = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final canApplyDiscount = ref.watch(permissionsProvider(shopId)).canApplyDiscount;
    final cs = Theme.of(context).colorScheme;
    // Fond panier = surface neutre cohérente avec les autres surfaces
    // (cards dashboard, inventaire). Pas de dégradé pour éviter la
    // dissonance visuelle inter-pages.
    //
    // En RESTAURATION uniquement, la surface est translucide pour laisser
    // deviner le décor de salle derrière le panier. Historique du réglage :
    // 0,60 → 0,40 (trop transparent, les lignes se noyaient dans la photo)
    // → 0,80 → 0,90. L'e-commerce garde un fond plein — sans ce garde, sa caisse
    // deviendrait illisible par-dessus la grille produits (cf. règle
    // « restaurant only »).
    final cartBg = isRestaurantShop(shopId)
        ? cs.surface.withValues(alpha: 0.90)
        : cs.surface;
    return LayoutBuilder(
        builder: (context, constraints) => BlocBuilder<CaisseBloc, CaisseState>(
          builder: (context, state) => ColoredBox(
            color: cartBg,
            child: SizedBox(
            height: constraints.maxHeight.isFinite
                ? constraints.maxHeight
                : MediaQuery.of(context).size.height * 0.85,
            child: Column(children: [
              // ── Header ────────────────────────────────────────────────
              _CartHeader(state: state, shopId: shopId),

              // ── Alerte prix ───────────────────────────────────────────
              if (state.priceAlerts.isNotEmpty)
                _PriceAlertBanner(alerts: state.priceAlerts),

              // ── Liste articles ─────────────────────────────────────────
              // Panier vide → empty state simple. Le mini-dashboard a été
              // retiré (utilisateur préférait l'empty state pur sans KPIs
              // qui parasitaient la concentration sur la vente en cours).
              Expanded(
                child: state.items.isEmpty
                    ? _EmptyCart(l: l)
                    : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  itemCount: state.items.length,
                  separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: Theme.of(context).semantic.borderSubtle,
                      indent: 16),
                  itemBuilder: (ctx, i) {
                    final item = state.items[i];
                    if (isRestaurantShop(shopId)) {
                      return _RestoCartItemRow(
                        item: item,
                        onDecrement: () => ctx.read<CaisseBloc>().add(
                            UpdateItemQuantity(item.productId,
                                item.quantity - 1,
                                variantName: item.variantName)),
                        onIncrement: () => ctx.read<CaisseBloc>().add(
                            UpdateItemQuantity(item.productId,
                                item.quantity + 1,
                                variantName: item.variantName)),
                        onEditQty: () => _showQtyEditor(ctx, item),
                        onEditPrice: () {
                          if (!canApplyDiscount) {
                            AppSnack.error(ctx,
                                'Action réservée : applique une remise '
                                'requiert la permission "sales.discount".');
                            return;
                          }
                          _showPriceEditor(ctx, item);
                        },
                        onRemove: () => ctx.read<CaisseBloc>().add(
                            RemoveItemFromCart(item.productId,
                                variantName: item.variantName)),
                      );
                    }
                    return _CartItemRow(
                      item:        item,
                      onDecrement: () => ctx.read<CaisseBloc>().add(
                          UpdateItemQuantity(item.productId,
                              item.quantity - 1,
                              variantName: item.variantName)),
                      onIncrement: () => ctx.read<CaisseBloc>().add(
                          UpdateItemQuantity(item.productId,
                              item.quantity + 1,
                              variantName: item.variantName)),
                      onEditQty: () => _showQtyEditor(ctx, item),
                      onEditPrice: () {
                        if (!canApplyDiscount) {
                          AppSnack.error(ctx,
                              'Action réservée : applique une remise '
                              'requiert la permission "sales.discount".');
                          return;
                        }
                        _showPriceEditor(ctx, item);
                      },
                    );
                  },
                ),
              ),

              // ── TVA seule (les frais sont désormais saisis dans le
              // sheet "Finaliser" au passage processing → completed,
              // le client + date dans le sheet "Enregistrer la commande"
              // au clic sur le bouton du panier). Allège le panier.
              if (state.items.isNotEmpty)
                _ClientTaxSection(shopId: shopId, state: state),

              // ── Récap + bouton ────────────────────────────────────────
              _CartFooter(shopId: shopId, state: state, l: l, isEcommerce: isEcommerce),
            ]),
          ),
          ),
        ));
  }

  void _showPriceEditor(BuildContext context, SaleItem item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _PriceEditorSheet(
        item:   item,
        bloc:   context.read<CaisseBloc>(),
        shopId: shopId,
      ),
    );
  }

  /// Éditeur de quantité — saisie numérique directe (au lieu de N taps sur +).
  void _showQtyEditor(BuildContext context, SaleItem item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _QtyEditorSheet(
        item: item,
        bloc: context.read<CaisseBloc>(),
      ),
    );
  }
}

/// Feuille de saisie directe de la quantité d'une ligne du panier.
class _QtyEditorSheet extends StatefulWidget {
  final SaleItem   item;
  final CaisseBloc bloc;
  const _QtyEditorSheet({required this.item, required this.bloc});
  @override
  State<_QtyEditorSheet> createState() => _QtyEditorSheetState();
}

class _QtyEditorSheetState extends State<_QtyEditorSheet> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: '${widget.item.quantity}');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final parsed = int.tryParse(_ctrl.text.trim());
    // Clamp ≥ 1 : retirer une ligne se fait via le bouton supprimer, pas en
    // mettant 0 ici.
    final qty = (parsed == null || parsed < 1) ? 1 : parsed;
    widget.bloc.add(UpdateItemQuantity(
        widget.item.productId, qty, variantName: widget.item.variantName));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
          left: 20, right: 20, top: 18,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Quantité', style: AppTextStyles.label),
          const SizedBox(height: 4),
          Text(
            widget.item.productName +
                (widget.item.variantName != null
                    ? ' — ${widget.item.variantName}'
                    : ''),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: AppTextStyles.captionHint,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: AppTextStyles.title,
            onSubmitted: (_) => _confirm(),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: theme.semantic.borderSubtle)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: AppColors.primary, width: 1.5)),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 46)),
                child: const Text('Annuler'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _confirm,
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 46)),
                child: const Text('Valider'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

/// Champ du COMPTE (addition) du panier.
///
/// Texte libre — « Compte 1 », « M. Ali », « Table 5 groupe fenêtre ». C'est
/// lui qui permet plusieurs additions sur une même table : deux commandes de
/// comptes différents ne se mélangent pas, même assises ensemble.
///
/// Sans table non plus : un compte à emporter est simplement une commande avec
/// un libellé et sans `tableId`.
class _OrderTabField extends StatefulWidget {
  final String? label;
  const _OrderTabField({required this.label});

  @override
  State<_OrderTabField> createState() => _OrderTabFieldState();
}

class _OrderTabFieldState extends State<_OrderTabField> {
  late final _ctrl = TextEditingController(text: widget.label ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _OrderTabField old) {
    super.didUpdateWidget(old);
    // Ne réécrire que si la valeur diffère : sinon le curseur sauterait au
    // début à chaque frappe (l'état change à chaque caractère).
    final incoming = widget.label ?? '';
    if (incoming != _ctrl.text) _ctrl.text = incoming;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: _ctrl,
      textCapitalization: TextCapitalization.sentences,
      style: AppTextStyles.input,
      onChanged: (v) => context.read<CaisseBloc>().add(SetOrderTab(v)),
      decoration: InputDecoration(
        hintText: 'Compte (ex. Compte 1, M. Ali…)',
        isDense: true,
        prefixIcon: const Icon(Icons.receipt_long_outlined, size: 18),
        suffixIcon: Icon(Icons.edit_rounded,
            size: 18, color: theme.colorScheme.primary),
      ),
    );
  }
}

/// Champ de note libre du panier (« sans piment », « table 4 »…).
///
/// Envoie `SetOrderNote` à CHAQUE frappe : la note doit survivre à un
/// enregistrement immédiat, sans dépendre d'une perte de focus. Le bloc
/// normalise (trim, vide → null), donc pas de doublon de logique ici.
class _OrderNoteField extends StatefulWidget {
  final String? note;
  const _OrderNoteField({required this.note});

  @override
  State<_OrderNoteField> createState() => _OrderNoteFieldState();
}

class _OrderNoteFieldState extends State<_OrderNoteField> {
  late final _ctrl = TextEditingController(text: widget.note ?? '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _OrderNoteField old) {
    super.didUpdateWidget(old);
    // Panier vidé / commande chargée pour édition : la note vient de l'état.
    // On ne réécrit QUE si elle diffère, sinon le curseur sauterait à chaque
    // frappe (l'état change à chaque caractère).
    final incoming = widget.note ?? '';
    if (incoming != _ctrl.text) _ctrl.text = incoming;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: _ctrl,
      textCapitalization: TextCapitalization.sentences,
      style: AppTextStyles.input,
      onChanged: (v) => context.read<CaisseBloc>().add(SetOrderNote(v)),
      decoration: InputDecoration(
        hintText: 'Ajouter une note…',
        isDense: true,
        prefixIcon: const Icon(Icons.sticky_note_2_outlined, size: 18),
        suffixIcon: Icon(Icons.edit_rounded,
            size: 18, color: theme.colorScheme.primary),
      ),
    );
  }
}

/// Taux de taxe lisible : « 10 » et non « 10.0 ».
String _fmtRate(double v) =>
    v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

// ─── Header ───────────────────────────────────────────────────────────────────
class _CartHeader extends StatelessWidget {
  final CaisseState state;
  final String      shopId;
  const _CartHeader({required this.state, required this.shopId});

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    // Mobile : header dense pour libérer de l'espace pour la liste.
    // Desktop : valeurs Material standard.
    final isCompact = MediaQuery.of(context).size.width < 900;
    return Container(
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(
              color: Theme.of(context).semantic.borderSubtle))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [

        // ── Titre + badge + vider ──────────────────────────────────
        Padding(
          padding: isCompact
              ? const EdgeInsets.fromLTRB(16, 8, 8, 4)
              : const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(children: [
            Icon(Icons.shopping_cart_outlined,
                size: isCompact ? 15 : 16,
                color: AppColors.textSecondary),
            SizedBox(width: isCompact ? 6 : 8),
            // En restauration : titre affirmé + décompte en sous-titre, comme
            // la maquette « Mon Panier ».
            if (isRestaurantShop(shopId))
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // `label` (14) et non `subtitleBold` (16) : le panier
                    // paraissait écrit plus gros que le reste de l'app.
                    Text('Mon Panier',
                        style: AppTextStyles.label.copyWith(
                            color: Theme.of(context).colorScheme.onSurface)),
                    Text(
                        state.itemCount == 0
                            ? 'Aucun article'
                            : '${state.itemCount} article'
                                '${state.itemCount > 1 ? 's' : ''} '
                                'sélectionné${state.itemCount > 1 ? 's' : ''}',
                        style: AppTextStyles.caption),
                  ],
                ),
              )
            else
              Expanded(child: Text(l.caisseCartTitle,
                  style: AppTextStyles.bodyBold)),
            if (state.itemCount > 0)
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: isCompact ? 7 : 8,
                    vertical: isCompact ? 2 : 3),
                decoration: BoxDecoration(color: AppColors.primary,
                    borderRadius: BorderRadius.circular(12)),
                child: Text('${state.itemCount}',
                    style: AppTextStyles.microBold
                        .copyWith(color: Colors.white)),
              ),
            // En restauration, le pied de panier porte déjà un bouton
            // « Vider » : ce raccourci rouge en tête faisait doublon, et deux
            // commandes destructrices à deux endroits invitent à l'erreur.
            if (state.items.isNotEmpty && !isRestaurantShop(shopId)) ...[
              SizedBox(width: isCompact ? 4 : 8),
              TextButton(
                onPressed: () =>
                    context.read<CaisseBloc>().add(ClearCart()),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.error,
                  padding: EdgeInsets.symmetric(
                      horizontal: isCompact ? 6 : 8,
                      vertical: isCompact ? 2 : 4),
                  minimumSize: Size.zero,
                ),
                child: Text(l.caisseClear,
                    style: AppTextStyles.caption
                        .copyWith(color: AppColors.error)),
              ),
            ],
          ]),
        ),

        // Zone client supprimée — le client est désormais sélectionné
        // dans le sheet "Enregistrer la commande" qui s'ouvre au clic
        // sur le bouton du panier (allège l'UI du panier, regroupe les
        // saisies métadonnées commande au moment de la décision).
        // `state.selectedClient` reste accessible côté bloc et est
        // affiché dans le footer si déjà saisi (pour transparence).
      ]),
    );
  }
}

// ─── Alerte prix ──────────────────────────────────────────────────────────────
class _PriceAlertBanner extends StatelessWidget {
  final List<SaleItem> alerts;
  const _PriceAlertBanner({required this.alerts});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppColors.warning.withValues(alpha:0.08),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.warning.withValues(alpha:0.35)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.warning_amber_rounded,
          size: 16, color: AppColors.warning),
      const SizedBox(width: 8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Alerte marge',
                  style: AppTextStyles.captionBold
                      .copyWith(color: AppColors.warning)),
              ...alerts.map((i) => Text(
                '• ${i.productName}${i.variantName != null ? ' — ${i.variantName}' : ''} : '
                    '${CurrencyFormatter.format(i.effectivePrice)} '
                    '(bénéf. < 50% du normal)',
                style: AppTextStyles.micro
                    .copyWith(color: Theme.of(context).colorScheme.onSurface),
              )),
            ]),
      ),
    ]),
  );
}

// ─── Ligne article ────────────────────────────────────────────────────────────
/// Ligne de panier — variante RESTAURATION (maquette « Mon Panier »).
///
/// Carte arrondie sombre : photo · nom · pastille prix unitaire · « × » ·
/// total de ligne en gros · quantité · corbeille.
///
/// Deux niveaux : identité du plat en haut (photo · nom · prix unitaire ·
/// corbeille à l'extrême droite), ajustement en bas (− quantité + · sous-total
/// de la ligne).
///
/// Décrémenter jusqu'à 0 retire la ligne : c'est déjà le comportement de
/// `UpdateItemQuantity` dans le bloc (`quantity <= 0` → `RemoveItemFromCart`),
/// donc aucune logique n'est dupliquée ici.
class _RestoCartItemRow extends StatelessWidget {
  final SaleItem     item;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final VoidCallback onEditQty;
  final VoidCallback onEditPrice;
  final VoidCallback onRemove;

  const _RestoCartItemRow({
    required this.item,
    required this.onDecrement,
    required this.onIncrement,
    required this.onEditQty,
    required this.onEditPrice,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final sem   = theme.semantic;
    final hasPriceAlert = item.isPriceAlertTriggered;
    final priceModified = item.customPrice != null;
    final amountColor = hasPriceAlert ? AppColors.warning : AppColors.primary;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sem.borderSubtle),
      ),
      // Tout sur UNE ligne : le stepper et le sous-total occupent l'espace qui
      // restait vide entre le prix unitaire et la corbeille. La ligne perd
      // ainsi la moitié de sa hauteur, et le panier affiche plus d'articles
      // sans défiler.
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        ProductImageCard(
          imageUrl: item.imageUrl,
          width: 44,
          height: 44,
          borderRadius: BorderRadius.circular(9),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(item.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
              const SizedBox(height: 5),
              // Pastille prix unitaire — tappable pour corriger le prix.
              InkWell(
                onTap: onEditPrice,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: amountColor.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(
                        priceModified
                            ? Icons.edit_rounded
                            : Icons.check_circle_rounded,
                        size: 13,
                        color: amountColor),
                    const SizedBox(width: 5),
                    Text(CurrencyFormatter.format(item.effectivePrice),
                        style: AppTextStyles.caption
                            .copyWith(color: amountColor)),
                  ]),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        // ── Stepper de quantité ────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: sem.borderSubtle),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            // À 1, « − » retire la ligne : le bloc traite quantity <= 0 comme
            // un retrait. L'icône change pour l'annoncer.
            _QtyBtn(
                dense: true,
                icon: item.quantity <= 1
                    ? Icons.delete_outline_rounded
                    : Icons.remove_rounded,
                onTap: onDecrement),
            // Quantité tappable → saisie directe, utile pour les grandes
            // quantités (10 bouteilles ne se tapent pas 10 fois).
            InkWell(
              onTap: onEditQty,
              child: Container(
                constraints: const BoxConstraints(minWidth: 30),
                padding: const EdgeInsets.symmetric(vertical: 6),
                alignment: Alignment.center,
                child: Text('${item.quantity}',
                    style:
                        AppTextStyles.bodyBold.copyWith(color: cs.onSurface)),
              ),
            ),
            _QtyBtn(
                dense: true, icon: Icons.add_rounded, onTap: onIncrement),
          ]),
        ),
        const SizedBox(width: 10),
        // ── Sous-total de la ligne ─────────────────────────────────────
        // `label` (14) et non `subtitleBold` (16) : à 16 le montant de ligne
        // rivalisait avec le TOTAL du panier, alors qu'il lui est subordonné.
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sous-total',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.micro),
              Text(CurrencyFormatter.format(item.subtotal),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.bodyBold.copyWith(color: amountColor)),
            ],
          ),
        ),
        // Respiration entre le montant et la corbeille : collés, le pouce
        // visait l'un en croyant toucher l'autre.
        const SizedBox(width: 10),
        // Corbeille à l'extrême droite, à l'écart du stepper : un doigt qui
        // vise « − » ne doit jamais supprimer la ligne par erreur.
        IconButton(
          onPressed: onRemove,
          tooltip: 'Retirer',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          icon: Icon(Icons.delete_outline_rounded,
              size: 19, color: sem.danger),
        ),
      ]),
    );
  }
}

class _CartItemRow extends StatelessWidget {
  final SaleItem     item;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final VoidCallback onEditQty;
  final VoidCallback onEditPrice;
  const _CartItemRow({
    required this.item,
    required this.onDecrement,
    required this.onIncrement,
    required this.onEditQty,
    required this.onEditPrice,
  });

  @override
  Widget build(BuildContext context) {
    final hasPriceAlert = item.isPriceAlertTriggered;
    final priceModified = item.customPrice != null;
    // Compactage mobile : seule l'IMAGE varie encore. Les tailles de police
    // passent par les échelons `AppTextStyles` — la règle du projet interdit
    // les `fontSize` en dur, et des valeurs sur mesure (9/10/11/12/13) rendaient
    // ce panier incohérent avec le reste de l'application.
    final isCompact = MediaQuery.of(context).size.width < 900;
    final imageSize = isCompact ? 36.0 : 44.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        // Image produit — ratio carré 1:1 unifié.
        ProductImageCard(
          imageUrl: item.imageUrl,
          width:    imageSize,
          height:   imageSize,
          borderRadius: BorderRadius.circular(8),
        ),
        const SizedBox(width: 10),
        // Infos produit
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.productName,
                    style: AppTextStyles.bodyBold,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                if (item.variantName != null)
                  Text(item.variantName!,
                      style: AppTextStyles.micro.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w500),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                // Prix + bouton édition prix (arrondi, fond teinté primary)
                GestureDetector(
                  onTap: onEditPrice,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      if (priceModified) ...[
                        Text(CurrencyFormatter.format(item.effectivePrice),
                            style: AppTextStyles.captionBold.copyWith(
                                color: hasPriceAlert
                                    ? AppColors.warning
                                    : AppColors.primary)),
                        Text(CurrencyFormatter.format(item.unitPrice),
                            style: AppTextStyles.micro.copyWith(
                                decoration: TextDecoration.lineThrough)),
                      ] else
                        Text(CurrencyFormatter.format(item.unitPrice),
                            style: AppTextStyles.captionBold
                                .copyWith(color: AppColors.primary)),
                      // Bouton arrondi avec fond teinté du primary actif —
                      // visible (vs l'ancienne icône 10px à 50% opacity).
                      // Tailles adaptées au breakpoint 900 (mobile/desktop).
                      Container(
                        width: isCompact ? 30 : 32,
                        height: isCompact ? 30 : 32,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(
                              isCompact ? 8 : 9),
                        ),
                        alignment: Alignment.center,
                        child: Icon(Icons.edit_rounded,
                            size: isCompact ? 16 : 18,
                            color: Theme.of(context).colorScheme.primary),
                      ),
                    ],
                  ),
                ),
              ]),
        ),
        const SizedBox(width: 8),
        // Sous-total + stepper
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(CurrencyFormatter.format(item.subtotal),
              style: AppTextStyles.captionBold.copyWith(
                  color: hasPriceAlert
                      ? AppColors.warning
                      : AppColors.primary)),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(color: AppColors.inputFill,
                borderRadius: BorderRadius.circular(8)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _QtyBtn(icon: Icons.remove_rounded, onTap: onDecrement),
              // Quantité tappable → saisie directe (évite N taps pour les
              // ventes en quantité / demi-gros).
              InkWell(
                onTap: onEditQty,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  child: Text('${item.quantity}',
                      style: isCompact
                          ? AppTextStyles.microBold
                          : AppTextStyles.bodyBold),
                ),
              ),
              _QtyBtn(icon: Icons.add_rounded, onTap: onIncrement),
            ]),
          ),
        ]),
      ]),
    );
  }
}

// ─── Section frais de commande ────────────────────────────────────────────────
// ignore: unused_element
class _FeesSection extends StatelessWidget {
  final String shopId;
  final CaisseState state;
  const _FeesSection({required this.shopId, required this.state});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
    decoration: BoxDecoration(
        border: Border(top: BorderSide(
            color: Theme.of(context).semantic.borderSubtle))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.local_shipping_outlined,
            size: 13, color: AppColors.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Frais de commande',
              style: AppTextStyles.captionBold),
        ),
        GestureDetector(
          onTap: () => _showAddFeeDialog(context, shopId),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_rounded, size: 12, color: AppColors.primary),
              const SizedBox(width: 3),
              Text('Ajouter', style: AppTextStyles.micro.copyWith(
                  fontWeight: FontWeight.w600, color: AppColors.primary)),
            ]),
          ),
        ),
      ]),
      if (state.fees.isNotEmpty) ...[
        const SizedBox(height: 6),
        ...state.fees.map((fee) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(children: [
            Expanded(
              child: GestureDetector(
                onTap: () => _showEditFeeDialog(context, fee, shopId),
                child: Row(children: [
                  Expanded(child: Text(fee.label,
                      style: AppTextStyles.captionHint.copyWith(
                          color: Theme.of(context).colorScheme.onSurface),
                      overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  Icon(Icons.edit_rounded, size: 10,
                      color: AppColors.primary.withValues(alpha:0.4)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            Text(CurrencyFormatter.format(fee.amount),
                style: AppTextStyles.captionBold.copyWith(
                    color: Theme.of(context).colorScheme.onSurface)),
            const SizedBox(width: 4),
            GestureDetector(
              onTap: () => context.read<CaisseBloc>()
                  .add(RemoveOrderFee(fee.id)),
              child: Icon(Icons.close_rounded,
                  size: 14, color: AppColors.textHint),
            ),
          ]),
        )),
      ],
    ]),
  );

  void _showAddFeeDialog(BuildContext context, String shopId) {
    final labelCtrl  = TextEditingController();
    final amountCtrl = TextEditingController();
    final suggestions = AppDatabase.getDistinctOrderFeeLabels(shopId);
    showAdaptiveFormSheet(
      context: context,
      builder: (dc) => AdaptiveFormFrame(
        title: 'Ajouter un frais',
        icon: Icons.local_shipping_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AutocompleteTextField(
                    controller:  labelCtrl,
                    label:       'Libellé',
                    hint:        'Ex: Frais de livraison',
                    prefixIcon:  Icons.label_outline_rounded,
                    suggestions: suggestions,
                  ),
                  const SizedBox(height: 10),
                  _FeeField(ctrl: amountCtrl,
                      hint: 'Montant (${CurrencyFormatter.currentSymbol})',
                      icon: Icons.payments_outlined,
                      inputType: TextInputType.number),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(dc).pop(),
                      child: Text('Annuler',
                          style: TextStyle(color: AppColors.textSecondary))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white, elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10))),
                    onPressed: () {
                      final label  = labelCtrl.text.trim();
                      final amount =
                          double.tryParse(amountCtrl.text.trim()) ?? 0;
                      if (label.isEmpty || amount <= 0) return;
                      Navigator.of(dc).pop();
                      context.read<CaisseBloc>().add(AddOrderFee(OrderFee(
                        id:     DateTime.now().millisecondsSinceEpoch.toString(),
                        label:  label,
                        amount: amount,
                      )));
                    },
                    child: const Text('Ajouter'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditFeeDialog(BuildContext context, OrderFee fee, String shopId) {
    final labelCtrl  = TextEditingController(text: fee.label);
    final amountCtrl = TextEditingController(text: fee.amount.toStringAsFixed(0));
    final suggestions = AppDatabase.getDistinctOrderFeeLabels(shopId);
    showAdaptiveFormSheet(
      context: context,
      builder: (dc) => AdaptiveFormFrame(
        title: 'Modifier le frais',
        icon: Icons.local_shipping_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AutocompleteTextField(
                    controller:  labelCtrl,
                    label:       'Libellé',
                    prefixIcon:  Icons.label_outline_rounded,
                    suggestions: suggestions,
                  ),
                  const SizedBox(height: 10),
                  _FeeField(ctrl: amountCtrl,
                      hint: 'Montant (${CurrencyFormatter.currentSymbol})',
                      icon: Icons.payments_outlined,
                      inputType: TextInputType.number),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.of(dc).pop(),
                      child: Text('Annuler',
                          style: TextStyle(color: AppColors.textSecondary))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white, elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10))),
                    onPressed: () {
                      final label  = labelCtrl.text.trim();
                      final amount =
                          double.tryParse(amountCtrl.text.trim()) ?? 0;
                      if (label.isEmpty || amount <= 0) return;
                      Navigator.of(dc).pop();
                      context.read<CaisseBloc>().add(UpdateOrderFee(
                          fee.id, label: label, amount: amount));
                    },
                    child: const Text('Enregistrer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


// ─── Section Client + TVA ─────────────────────────────────────────────────────
class _ClientTaxSection extends StatelessWidget {
  final String      shopId;
  final CaisseState state;
  const _ClientTaxSection({required this.shopId, required this.state});

  @override
  Widget build(BuildContext context) {
    // Lecture du toggle "TVA activée" (Paramètres → Caisse). Quand il est
    // désactivé : la ligne TVA disparaît du panier ET on remet à zéro le
    // taux côté Bloc — sinon un taux saisi avant la désactivation
    // continuerait à gonfler le total via `state.taxAmount`.
    final taxEnabled = ShopSettingsStore(shopId)
        .read<bool>('caisse_tax_enabled', fallback: false) ?? false;
    if (!taxEnabled) {
      if ((state.taxRate) > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          context.read<CaisseBloc>().add(SetTaxRate(0));
        });
      }
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      decoration: BoxDecoration(
          border: Border(top: BorderSide(
              color: Theme.of(context).semantic.borderSubtle))),
      child: _TvaLine(state: state),
    );
  }
}


// ─── Bottom sheet sélection client ───────────────────────────────────────────
// ignore: unused_element
class _ClientPickerSheet extends StatefulWidget {
  final String     shopId;
  final CaisseBloc bloc;
  final Client?    selected;
  const _ClientPickerSheet({
    // ignore: unused_element_parameter
    required this.shopId, required this.bloc, this.selected});
  @override
  State<_ClientPickerSheet> createState() => _ClientPickerSheetState();
}

class _ClientPickerSheetState extends State<_ClientPickerSheet> {
  String _query  = '';
  List<Client> _clients = [];

  @override
  void initState() {
    super.initState();
    _clients = AppDatabase.getClientsForShop(widget.shopId);
  }

  List<Client> get _filtered => _query.isEmpty
      ? _clients
      : _clients.where((c) =>
  c.name.toLowerCase().contains(_query.toLowerCase()) ||
      (c.phone?.contains(_query) ?? false)).toList();

  @override
  Widget build(BuildContext context) => DraggableScrollableSheet(
    initialChildSize: 0.65,
    minChildSize:     0.4,
    maxChildSize:     0.9,
    expand: false,
    builder: (_, sc) => Column(children: [
      // Poignée
      Container(
          margin: const EdgeInsets.only(top: 10, bottom: 8),
          width: 36, height: 4,
          decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2))),

      // Titre — restitué tel qu'avant (pas de X demandé sur cette page).
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(Icons.person_search_rounded,
                  size: 17, color: AppColors.primary)),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Sélectionner un client',
                style: AppTextStyles.subtitleBold),
          ),
          // Bouton nouveau client
          GestureDetector(
            onTap: () => _showCreateClient(context),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(8)),
              child: Row(
                  mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.person_add_rounded,
                    size: 13, color: Colors.white),
                const SizedBox(width: 4),
                Text('Nouveau', style: AppTextStyles.captionBold
                    .copyWith(color: Colors.white)),
              ]),
            ),
          ),
        ]),
      ),

      // Recherche
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        child: TextField(
          onChanged: (v) => setState(() => _query = v),
          style: AppTextStyles.body,
          decoration: InputDecoration(
            hintText: 'Rechercher par nom ou téléphone…',
            hintStyle: AppTextStyles.bodySm
                .copyWith(color: AppColors.textHint),
            prefixIcon: Icon(Icons.search_rounded,
                size: 16, color: AppColors.textHint),
            filled: true, fillColor: AppColors.inputFill,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                    color: Theme.of(context).semantic.borderSubtle)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                    color: Theme.of(context).semantic.borderSubtle)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                    color: AppColors.primary, width: 1.5)),
          ),
        ),
      ),
      Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),

      // Liste clients
      Expanded(
        child: _filtered.isEmpty
            ? Center(
            child: Column(
                mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.person_off_outlined,
                  size: 36, color: AppColors.divider),
              const SizedBox(height: 8),
              Text(
                  _query.isEmpty
                      ? 'Aucun client enregistré'
                      : 'Aucun résultat pour "$_query"',
                  style: AppTextStyles.body
                      .copyWith(color: AppColors.textHint)),
            ]))
            : ListView.separated(
          controller:  sc,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount:   _filtered.length,
          separatorBuilder: (_, __) => Divider(
              height: 1, color: AppColors.inputFill,
              indent: 56),
          itemBuilder: (_, i) {
            final c   = _filtered[i];
            final sel = c.id == widget.selected?.id;
            return ListTile(
              dense: true,
              leading: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha:0.1),
                    shape: BoxShape.circle),
                child: Center(child: Text(
                  c.name[0].toUpperCase(),
                  style: AppTextStyles.label.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary),
                )),
              ),
              title: Text(c.name,
                  style: AppTextStyles.body.copyWith(
                      fontWeight: sel
                          ? FontWeight.w700 : FontWeight.w500,
                      color: sel
                          ? AppColors.primary
                          : Theme.of(context).colorScheme.onSurface)),
              subtitle: c.phone != null
                  ? Text(c.phone!,
                  style: AppTextStyles.captionHint)
                  : null,
              trailing: sel
                  ? Icon(Icons.check_circle_rounded,
                  color: AppColors.primary, size: 18)
                  : null,
              selected: sel,
              selectedTileColor:
              AppColors.primarySurface,
              onTap: () {
                widget.bloc.add(SetSelectedClient(c));
                Navigator.of(context).pop();
              },
            );
          },
        ),
      ),
    ]),
  );

  void _showCreateClient(BuildContext context) {
    // Capturer le bloc AVANT de fermer le picker
    // (le bloc reste valide même après dispose du picker)
    final bloc     = widget.bloc;
    final shopId   = widget.shopId;

    Navigator.of(context).pop();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Bascule en page pleine sur mobile (gestion clavier native par le
      // Scaffold), reste un sheet sur desktop. Cf. AdaptiveFormFrame.
      showAdaptiveFormSheet(
        context: this.context,
        builder: (ctx) => ClientFormSheet(
          shopId: shopId,
          onSaved: () {
            Navigator.of(ctx).pop();
            // Récupérer le dernier client créé depuis Hive
            final all = AppDatabase.getClientsForShop(shopId);
            if (all.isNotEmpty) {
              final newest = all.reduce((a, b) =>
              a.createdAt.isAfter(b.createdAt) ? a : b);
              // Sélectionner via le bloc (stable, indépendant du widget tree)
              bloc.add(SetSelectedClient(newest));
            }
          },
        ),
      );
    });
  }
}

// ─── Footer récap ─────────────────────────────────────────────────────────────
class _CartFooter extends StatelessWidget {
  final String shopId;
  final CaisseState state;
  final AppLocalizations l;
  final bool isEcommerce;
  const _CartFooter({required this.shopId, required this.state,
    required this.l, this.isEcommerce = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
        // En restauration, TRANSPARENT : le panier peint déjà son fond
        // translucide sur toute sa hauteur (cf. `cartBg`). Repeindre ici une
        // surface pleine créait une seconde couche opaque, et le bas du panier
        // devenait un aplat alors que le haut laissait voir le décor.
        color: isRestaurantShop(shopId)
            ? Colors.transparent
            : Theme.of(context).colorScheme.surface,
        border: Border(top: BorderSide(
            color: Theme.of(context).semantic.borderSubtle))),
    child: Column(children: [
      // Note libre — restauration uniquement. Persistée sur `Sale.notes` via
      // `SetOrderNote` : ce n'est pas un champ décoratif.
      if (isRestaurantShop(shopId)) ...[
        _OrderTabField(label: state.tabLabel),
        const SizedBox(height: 8),
        _OrderNoteField(note: state.note),
        const SizedBox(height: 10),
      ],
      _Line(l.caisseSubtotal, CurrencyFormatter.format(state.subtotal)),
      // Ligne de taxe : affichée dès qu'un taux est configuré sur la vente.
      // Elle existait déjà dans le calcul du total (`state.taxAmount`) mais
      // n'apparaissait nulle part — le client voyait un total supérieur à la
      // somme des lignes sans explication.
      if (state.taxRate > 0) ...[
        const SizedBox(height: 4),
        _Line('Taxe (${_fmtRate(state.taxRate)} %)',
            CurrencyFormatter.format(state.taxAmount)),
      ],
      if (state.totalFees > 0) ...[
        const SizedBox(height: 4),
        _Line('Frais', CurrencyFormatter.format(state.totalFees)),
      ],
      if (state.discountAmount > 0) ...[
        const SizedBox(height: 4),
        _Line(l.caisseDiscount,
            '- ${CurrencyFormatter.format(state.discountAmount)}',
            color: AppColors.warning),
      ],
      const SizedBox(height: 10),
      // Bloc TOTAL mis en relief : fond teinté primaire + bordure + montant
      // agrandi (échelon `title`). Donne le relief qui manquait pour que le
      // caissier relise le montant avant de valider (au lieu du même fond
      // blanc que les articles).
      // En restauration : ligne simple « Total : » + montant, comme la
      // maquette. Ailleurs : bloc encadré, qui donne le relief nécessaire au
      // caissier pour relire le montant avant de valider.
      if (isRestaurantShop(shopId))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text('${l.total} :',
                    style: AppTextStyles.label.copyWith(
                        color: Theme.of(context).colorScheme.onSurface)),
                Flexible(
                  child: Text(CurrencyFormatter.format(state.total),
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.subtitleBold
                          .copyWith(color: AppColors.primary)),
                ),
              ]),
        )
      else
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.20)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center, children: [
            Text(l.total.toUpperCase(),
                style: AppTextStyles.subtitleBold.copyWith(
                    fontWeight: FontWeight.w800, color: AppColors.primary)),
            Flexible(
              child: Text(CurrencyFormatter.format(state.total),
                  textAlign: TextAlign.end,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.title.copyWith(color: AppColors.primary)),
            ),
          ]),
        ),
      const SizedBox(height: 12),
      // Date de livraison déplacée vers le sheet "Enregistrer la commande"
      // qui s'ouvre au clic sur le bouton du panier (allège l'UI panier).
      SizedBox(
          width: double.infinity,
          child: Builder(builder: (btnCtx) {
            final isCompact = MediaQuery.of(btnCtx).size.width < 900;
            final iconSize  = isCompact ? 14.0 : 18.0;
            final btnPad    = isCompact
                ? const EdgeInsets.symmetric(vertical: 8)
                : const EdgeInsets.symmetric(vertical: 13);
            final btnMinH   = isCompact
                ? const Size.fromHeight(34)
                : const Size.fromHeight(46);
            final btnRadius = isCompact ? 8.0 : 10.0;
            // Raison du blocage (si présent) — utilisée pour snackbar.
            // Le client est désormais demandé DANS le sheet "Enregistrer la
            // commande" qui s'ouvre au clic — donc on ne le bloque plus ici.
            String? missing;
            if (state.items.isEmpty) {
              missing = 'Ajoute au moins un article au panier.';
            } else if ((state.deliveryLocationId ?? '').isEmpty) {
              // Principe métier : toute commande doit être rattachée à un
              // lieu (boutique principale OU dépôt partenaire). En vue
              // Globale (aucun chip sélectionné), pas de vente possible.
              missing = 'Sélectionne une boutique ou un partenaire avant de vendre.';
            }
            final blockedBecauseProcessing = state.isProcessing;
            final blockedBecauseSaved      = state.orderSaved == true;
            final isBlocked = missing != null
                || blockedBecauseProcessing
                || blockedBecauseSaved;

            // Couleurs liées au thème actif — change automatiquement quand
            // l'utilisateur bascule de palette dans Paramètres → Thème.
            final theme   = Theme.of(context);
            final cs      = theme.colorScheme;
            final sem     = theme.semantic;
            // L'état « bloqué » se signalait par une transparence de 0,45 —
            // par-dessus un panier translucide, le bouton devenait olive et
            // illisible. En restauration on compose cette teinte sur la
            // surface : même atténuation visuelle, opacité pleine.
            final resto = isRestaurantShop(shopId);
            final bgColor = blockedBecauseSaved
                ? sem.success
                : isBlocked
                    ? (resto
                        ? Color.alphaBlend(
                            cs.primary.withValues(alpha: 0.45), cs.surface)
                        : cs.primary.withValues(alpha: 0.45))
                    : cs.primary;

            VoidCallback? buildOnPressed() {
              // Toujours tappable : si bloqué, on affiche un snackbar ;
              // sinon on dispatche l'event.
              return () async {
                if (missing != null) {
                  AppSnack.error(context, missing);
                  return;
                }
                if (blockedBecauseProcessing || blockedBecauseSaved) return;
                if (isEcommerce) {
                  // Sheet A : recueille client + date livraison + lieu
                  // (ville + quartier pré-remplis depuis le client). Le
                  // mode et locationId restent ceux déjà set par les chips
                  // (boutique ou partenaire), pas demandés ici.
                  final bloc = context.read<CaisseBloc>();
                  final st   = bloc.state;
                  final res  = await showOrderCreationSheet(
                    context,
                    shopId:         shopId,
                    initialClient:  st.selectedClient,
                    initialDate:    st.deliveryDate,
                    initialCity:    st.deliveryCity,
                    initialAddress: st.deliveryAddress,
                    // PRODUITS SEULS (hors livraison) : le sheet ajoute lui-même
                    // les frais de livraison du quartier choisi. Soustraire
                    // st.deliveryPrice évite le double-comptage en édition.
                    orderTotal:     st.total - st.deliveryPrice,
                    initialIsApprovalSale: st.isApprovalSale,
                    lockApproval:          st.editingOrderId != null,
                    // FIX 2 — transmet le mode courant : en pickup le sheet
                    // masque/optionnalise ville/quartier.
                    deliveryMode:          st.deliveryMode,
                    // Livraison par quartier (PR-2) — pré-remplissage édition.
                    initialDeliveryPrice:  st.deliveryPrice,
                    initialQuartier:       st.deliveryQuartier,
                    initialZone:           st.deliveryZone,
                  );
                  if (res == null) return; // annulé
                  if (!context.mounted) return;
                  bloc
                    ..add(SetSelectedClient(res.client))
                    ..add(SetDeliveryDate(res.scheduledAt))
                    ..add(SetDeliveryDetails(
                      // mode / locationId conservés (chips actifs)
                      deliveryCity:     res.deliveryCity,
                      deliveryAddress:  res.deliveryAddress,
                      deliveryQuartier: res.deliveryQuartier,
                      deliveryZone:     res.deliveryZone,
                      deliveryPrice:    res.deliveryPrice,
                    ))
                    ..add(SaveOrder(shopId,
                        createdAt:      res.createdAt,
                        amountPaid:     res.amountPaid,
                        isApprovalSale: res.isApprovalSale));
                } else {
                  context.push('/shop/$shopId/caisse/payment');
                }
              };
            }

            final buttonStyle = ElevatedButton.styleFrom(
              backgroundColor: bgColor,
              foregroundColor: Colors.white,
              elevation: 0,
              minimumSize: btnMinH,
              padding: btnPad,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(btnRadius)),
            );

            // ── RESTAURATION : Vider · Commander · Payer ────────────────
            //
            // « Payer » n'invente aucun flux : il ouvre la page de paiement
            // (`/caisse/payment`), celle qu'empruntait déjà la caisse hors
            // e-commerce. Elle était devenue inatteignable depuis que
            // `kEcommerceOnlyMode` impose « Enregistrer la commande ».
            //
            // Le garde est `isRestaurantShop(shopId)` — déterministe par
            // boutique, et non l'ancien `currentShopProvider` non réactif qui
            // faisait apparaître le mauvais bouton en e-commerce.
            if (resto) {
              final secondaryStyle = ElevatedButton.styleFrom(
                // OPAQUE : un fond en alpha laissait passer le décor et
                // délavait le libellé (« Payer » quasi illisible). On compose
                // l'incrustation sur la surface pour obtenir la même teinte en
                // pleine opacité.
                backgroundColor: restoOpaqueOverlay(context, 0.10),
                foregroundColor: cs.onSurface,
                // États désactivés OPAQUES eux aussi : par défaut Material
                // applique une opacité de 0,12 qui laissait « Payer » quasi
                // invisible par-dessus le décor.
                disabledBackgroundColor: restoOpaqueOverlay(context, 0.06),
                disabledForegroundColor:
                    cs.onSurface.withValues(alpha: 0.45),
                elevation: 0,
                minimumSize: btnMinH,
                padding: btnPad,
                textStyle: AppTextStyles.label,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(btnRadius)),
              );
              return Row(children: [
                Expanded(
                  child: ElevatedButton(
                    style: secondaryStyle,
                    onPressed: state.items.isEmpty
                        ? null
                        : () => context.read<CaisseBloc>().add(ClearCart()),
                    child: const Text('Vider'),
                  ),
                ),
                const SizedBox(width: 10),
                // Action principale — même comportement que le bouton unique
                // (sheet de création puis SaveOrder).
                Expanded(
                  flex: 2,
                  child: Tooltip(
                    message: missing ?? '',
                    triggerMode: missing == null
                        ? TooltipTriggerMode.manual
                        : TooltipTriggerMode.longPress,
                    child: ElevatedButton(
                      style: buttonStyle,
                      onPressed: buildOnPressed(),
                      child: Text(state.orderSaved == true
                          ? 'Commande enregistrée ✓'
                          : 'Commander'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    style: secondaryStyle,
                    onPressed: isBlocked
                        ? null
                        : () => context.push('/shop/$shopId/caisse/payment'),
                    child: const Text('Payer'),
                  ),
                ),
              ]);
            }

            final btn = isEcommerce
                ? ElevatedButton.icon(
                    icon: state.isProcessing
                        ? SizedBox(width: iconSize, height: iconSize,
                            child: const CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Icon(Icons.save_outlined, size: iconSize),
                    label: Text(state.orderSaved == true
                        ? (state.editingOrderId != null
                            ? 'Modifications enregistrées ✓'
                            : 'Commande enregistrée ✓')
                        : (state.editingOrderId != null
                            ? 'Mettre à jour la commande'
                            : 'Enregistrer la commande')),
                    onPressed: buildOnPressed(),
                    style: buttonStyle,
                  )
                : ElevatedButton.icon(
                    icon: Icon(Icons.point_of_sale_rounded, size: iconSize),
                    label: Text(l.caissePay),
                    onPressed: buildOnPressed(),
                    style: buttonStyle,
                  );
            // Tooltip toujours présent quand bloqué — montre la raison
            // au survol desktop et au long-press mobile.
            return Tooltip(
              message: missing ?? '',
              triggerMode: missing == null
                  ? TooltipTriggerMode.manual
                  : TooltipTriggerMode.longPress,
              child: btn,
            );
          }),
        ),
    ]),
  );
}


// ─── Ligne TVA avec édition ─────────────────────────────────────────────────
class _TvaLine extends StatelessWidget {
  final CaisseState state;
  const _TvaLine({required this.state});

  String get _currency {
    try {
      final user = LocalStorageService.getCurrentUser();
      if (user?.phone == null) return 'XAF';
      final sorted = kCountries.toList()
        ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
      for (final c in sorted) {
        if (user!.phone!.startsWith(c.dialCode)) {
          return switch (c.isoCode) {
            'CM'||'TD'||'CF'||'CG'||'GA'||'GQ' => 'XAF',
            'SN'||'CI'||'BF'||'ML'||'NE'||'TG'||'BJ' => 'XOF',
            'NG' => 'NGN', 'GH' => 'GHS', 'MA' => 'MAD',
            'FR'||'BE'||'DE'||'IT'||'ES' => 'EUR',
            'US' => 'USD', 'GB' => 'GBP',
            _ => 'XAF',
          };
        }
      }
    } catch (_) {}
    return 'XAF';
  }

  void _showTaxDialog(BuildContext context) {
    final rate = state.taxRate;
    final ctrl = TextEditingController(
        text: rate == 0 ? '' : rate.toStringAsFixed(
            rate % 1 == 0 ? 0 : 2));
    showAdaptiveFormSheet(
      context: context,
      builder: (dc) => AdaptiveFormFrame(
        title: 'Taux de TVA',
        icon: Icons.receipt_long_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(
                        RegExp(r'[0-9.]'))],
                    style: AppTextStyles.subtitleBold,
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: '0',
                      hintStyle: TextStyle(color: AppColors.textHint),
                      suffixText: '%',
                      suffixStyle: AppTextStyles.label
                          .copyWith(color: AppColors.primary),
                      filled: true,
                      fillColor: AppColors.primarySurface,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 13),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                              color: AppColors.primary, width: 1.5)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                              color: AppColors.primary.withValues(alpha:0.3),
                              width: 1)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                              color: AppColors.primary, width: 1.5)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Laissez vide ou 0 pour aucune TVA',
                      style: AppTextStyles.captionHint),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                      onPressed: () => Navigator.of(dc).pop(),
                      child: Text('Annuler',
                          style: TextStyle(color: AppColors.textSecondary))),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10))),
                    onPressed: () {
                      final v = double.tryParse(ctrl.text.trim()) ?? 0;
                      Navigator.of(dc).pop();
                      context.read<CaisseBloc>()
                          .add(SetTaxRate(v.clamp(0, 100)));
                    },
                    child: const Text('Appliquer'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rate     = state.taxRate;
    final currency = _currency;
    final amount   = state.taxAmount;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('TVA',
            style: AppTextStyles.bodySmSecondary),
        Row(mainAxisSize: MainAxisSize.min, children: [
          RichText(
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: AppTextStyles.bodySm.copyWith(
                  color: rate > 0
                      ? Theme.of(context).colorScheme.onSurface
                      : AppColors.textHint),
              children: [
                TextSpan(
                  text: rate == 0
                      ? '0'
                      : '+${CurrencyFormatter.format(amount)}',
                  style: TextStyle(
                      fontWeight: rate > 0
                          ? FontWeight.w600
                          : FontWeight.normal),
                ),
                TextSpan(
                  text: ' $currency',
                  style: AppTextStyles.micro
                      .copyWith(fontWeight: FontWeight.w500),
                ),
                if (rate > 0)
                  TextSpan(
                    text: '  ',
                    style: AppTextStyles.micro,
                  ),
                if (rate > 0)
                  TextSpan(
                    text: '(${rate.toStringAsFixed(rate % 1 == 0 ? 0 : 2)}%)',
                    style: AppTextStyles.micro,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => _showTaxDialog(context),
            child: Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha:0.3)),
              ),
              child: Icon(Icons.edit_rounded,
                  size: 12, color: AppColors.primary),
            ),
          ),
        ]),
      ],
    );
  }
}


class _Line extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _Line(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: AppTextStyles.bodySm
          .copyWith(color: color ?? AppColors.textSecondary)),
      Text(value,  style: AppTextStyles.bodySm
          .copyWith(color: color ?? Theme.of(context).colorScheme.onSurface)),
    ],
  );
}

// ─── Sheet édition de prix ────────────────────────────────────────────────────
class _PriceEditorSheet extends ConsumerStatefulWidget {
  final SaleItem   item;
  final CaisseBloc bloc;
  final String     shopId;
  const _PriceEditorSheet({
    required this.item,
    required this.bloc,
    required this.shopId,
  });
  @override
  ConsumerState<_PriceEditorSheet> createState() => _PriceEditorSheetState();
}

enum _MarginStatus { ok, low, below, unknown }

class _PriceEditorSheetState extends ConsumerState<_PriceEditorSheet> {
  static const _minMarginPct = 30.0;

  late TextEditingController _ctrl;
  // Section repliable des raccourcis de remise — fermée par défaut pour
  // raccourcir le sheet (évite que le bouton « Appliquer » soit caché).
  bool _shortcutsExpanded = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
        text: (widget.item.customPrice ?? widget.item.unitPrice)
            .toStringAsFixed(0));
    // Sélection totale d'emblée : combiné à l'autofocus, taper remplace
    // directement la valeur sans avoir à l'effacer (édition plus rapide).
    _ctrl.selection = TextSelection(
        baseOffset: 0, extentOffset: _ctrl.text.length);
    _ctrl.addListener(() => setState(() {}));
  }

  /// Renseigne le champ prix programmatiquement (raccourcis de remise) et
  /// place le curseur en fin. Le listener rafraîchit l'aperçu marge.
  void _setPrice(double v) {
    final txt = v.toStringAsFixed(0);
    _ctrl.value = TextEditingValue(
      text: txt,
      selection: TextSelection.collapsed(offset: txt.length),
    );
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  double get _priceBuy => widget.item.priceBuy;
  double get _minPrice => _priceBuy * (1 + _minMarginPct / 100);

  /// Suivi de marge par prix d'achat : pertinent en e-commerce uniquement.
  /// En restaurant, la rentabilité gastronomique se pilote par la fiche
  /// recette (module Finances restaurant), pas par le prix d'achat de la
  /// ligne → on désactive toute l'alerte de marge (statut, avertissement
  /// « sous le coût », aperçu). L'édition de prix elle-même reste possible.
  bool get _marginTracked => !isRestaurantShop(widget.shopId);

  /// Calcule la marge (%) à partir du prix saisi.
  double? _currentMargin(double price) {
    if (_priceBuy <= 0 || price <= 0) return null;
    return (price - _priceBuy) / price * 100;
  }

  _MarginStatus _status(double? price) {
    if (!_marginTracked) return _MarginStatus.unknown;
    if (price == null || price <= 0) return _MarginStatus.unknown;
    if (_priceBuy <= 0) return _MarginStatus.unknown;
    if (price < _priceBuy) return _MarginStatus.below;
    if (price < _minPrice) return _MarginStatus.low;
    return _MarginStatus.ok;
  }

  Color _colorFor(_MarginStatus s) => switch (s) {
    _MarginStatus.ok      => AppColors.secondary,
    _MarginStatus.low     => AppColors.warning,
    _MarginStatus.below   => AppColors.error,
    _MarginStatus.unknown => AppColors.primary,
  };

  /// Dialog de confirmation quand 0 ≤ marge < 30%.
  Future<bool> _confirmLowMargin(double price, double marginPct,
      {bool belowCost = false}) async {
    final l = context.l10n;
    // Vente à perte (sous le prix de revient) : accent rouge + textes dédiés ;
    // marge basse (<30%) : accent orange.
    final accent = belowCost ? AppColors.error : AppColors.warning;
    final title  = belowCost ? l.priceEditBelowCostTitle : l.priceEditConfirmTitle;
    final body   = belowCost ? l.priceEditBelowCostBody  : l.priceEditConfirmBody;
    return await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        title: Row(children: [
          Container(width: 32, height: 32,
              decoration: BoxDecoration(
                  color: accent.withValues(alpha:0.14),
                  borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.warning_amber_rounded,
                  size: 17, color: accent)),
          const SizedBox(width: 10),
          Expanded(child: Text(title,
              style: AppTextStyles.subtitleBold)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(body,
              style: AppTextStyles.body.copyWith(height: 1.4)),
          const SizedBox(height: 10),
          _kvRow(l.priceEditCost,
              CurrencyFormatter.format(_priceBuy),
              AppColors.textSecondary),
          const SizedBox(height: 3),
          _kvRow('${l.priceEditApply} :',
              CurrencyFormatter.format(price),
              AppColors.textPrimary),
          const SizedBox(height: 3),
          _kvRow(l.priceEditMargin,
              '${marginPct.toStringAsFixed(0)}%',
              accent),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dc).pop(false),
            child: Text(l.commonCancel,
                style: TextStyle(color: AppColors.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.warning,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.of(dc).pop(true),
            child: Text(l.priceEditConfirmKeep),
          ),
        ],
      ),
    ) ?? false;
  }

  Widget _kvRow(String label, String value, Color valueColor) =>
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(label, style: AppTextStyles.bodySmSecondary),
        Text(value, style: AppTextStyles.bodySmBold
            .copyWith(color: valueColor)),
      ]);

  Future<void> _apply() async {
    final v = double.tryParse(_ctrl.text);
    if (v == null || v <= 0) return;
    final s = _status(v);
    // Garde défensive : re-vérifier la permission au moment du dispatch.
    // L'UX a déjà été gardée à l'ouverture du sheet (cart_widget), mais
    // on revérifie ici pour couvrir le cas où la permission a changé
    // pendant l'édition (révocation Realtime) ou tout futur call site
    // qui ouvrirait le sheet sans vérifier.
    final canDiscount = ref.read(permissionsProvider(widget.shopId))
        .canApplyDiscount;
    if (!canDiscount) {
      AppSnack.error(context,
          'Action réservée : appliquer une remise requiert la '
          'permission "sales.discount".');
      return;
    }
    // Alerte + confirmation si marge basse (<30%) OU vente à perte (prix sous
    // le prix de revient). On ALERTE mais on AUTORISE (déstockage possible).
    if (s == _MarginStatus.low || s == _MarginStatus.below) {
      final margin = _currentMargin(v) ?? 0;
      final ok = await _confirmLowMargin(v, margin,
          belowCost: s == _MarginStatus.below);
      if (!ok) return;
    }
    widget.bloc.add(UpdateItemPrice(widget.item.productId, v,
        variantName: widget.item.variantName));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l        = context.l10n;
    final original = widget.item.unitPrice;
    final typed    = double.tryParse(_ctrl.text);
    final status   = _status(typed);
    final color    = _colorFor(status);
    final margin   = typed != null ? _currentMargin(typed) : null;
    final costKnown = _priceBuy > 0 && _marginTracked;

    final message = switch (status) {
      _MarginStatus.ok      => margin != null
          ? l.priceEditMarginOk(margin) : null,
      _MarginStatus.low     => margin != null
          ? l.priceEditMarginLow(margin) : null,
      _MarginStatus.below   => l.priceEditBelowCost,
      _MarginStatus.unknown => null,
    };

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      // Scrollable : avec le clavier ouvert, le contenu peut dépasser la
      // hauteur disponible. Sans scroll, le bouton « Appliquer » du bas
      // restait caché → on enveloppe tout dans un SingleChildScrollView.
      child: SingleChildScrollView(
        child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Poignée
          Center(child: Container(width: 36, height: 4,
              decoration: BoxDecoration(color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 16),

          // Titre
          Row(children: [
            Container(width: 36, height: 36,
                decoration: BoxDecoration(color: AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(9)),
                child: Icon(Icons.price_change_outlined,
                    size: 18, color: AppColors.primary)),
            const SizedBox(width: 10),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${widget.item.productName}'
                  '${widget.item.variantName != null
                      ? ' — ${widget.item.variantName}' : ''}',
                  style: AppTextStyles.label
                      .copyWith(fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(l.priceEditSubtitle,
                  style: AppTextStyles.captionHint),
            ])),
          ]),
          const SizedBox(height: 16),

          // Champ saisie
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(
                RegExp(r'[0-9.]'))],
            style: AppTextStyles.title,
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              hintText: '0',
              suffixText: CurrencyFormatter.currentSymbol,
              suffixStyle: AppTextStyles.body.copyWith(color: color),
              filled: true,
              fillColor: color.withValues(alpha:0.06),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 16),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: color, width: 1.5)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                      color: color.withValues(alpha:0.5), width: 1.5)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: color, width: 2)),
            ),
          ),
          const SizedBox(height: 10),
          // Raccourcis de remise repliables : applique une valeur en 1 tap
          // (édition rapide). Fermés par défaut pour raccourcir le sheet ;
          // le statut marge se met à jour en temps réel et bloque toujours
          // si on passe sous le prix de revient.
          InkWell(
            onTap: () => setState(
                () => _shortcutsExpanded = !_shortcutsExpanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Icon(Icons.local_offer_outlined,
                    size: 15, color: AppColors.primary),
                const SizedBox(width: 6),
                Text(l.priceEditQuickDiscounts,
                    style: AppTextStyles.bodySmBold
                        .copyWith(color: AppColors.primary)),
                const Spacer(),
                AnimatedRotation(
                  turns: _shortcutsExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      size: 20, color: AppColors.primary),
                ),
              ]),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _shortcutsExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8, runSpacing: 8, alignment: WrapAlignment.center,
                children: [
                  _QuickPriceChip(
                    label: l.priceEditOriginal,
                    onTap: () => _setPrice(original),
                  ),
                  for (final pct in const [5, 10, 15])
                    _QuickPriceChip(
                      label: '-$pct%',
                      onTap: () => _setPrice(
                          (original * (1 - pct / 100)).roundToDouble()),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Infos temps réel
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: Theme.of(context).semantic.borderSubtle)),
            child: Column(children: [
              _kvRow(l.priceEditOriginal,
                  CurrencyFormatter.format(original),
                  AppColors.textPrimary),
              // Coût / marge : e-commerce uniquement. En restaurant, tout le
              // bloc est masqué (la rentabilité passe par la fiche recette).
              if (_marginTracked) ...[
                const SizedBox(height: 4),
                _kvRow(
                  l.priceEditCost,
                  costKnown
                      ? CurrencyFormatter.format(_priceBuy)
                      : l.priceEditCostUnknown,
                  AppColors.textSecondary,
                ),
                if (costKnown) ...[
                  const SizedBox(height: 4),
                  _kvRow(
                    l.priceEditMinPrice,
                    CurrencyFormatter.format(_minPrice),
                    AppColors.warning,
                  ),
                  if (margin != null) ...[
                    const SizedBox(height: 4),
                    _kvRow(
                      l.priceEditMargin,
                      '${margin.toStringAsFixed(0)}%',
                      color,
                    ),
                  ],
                ],
              ],
            ]),
          ),

          // Message d'état
          if (message != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: color.withValues(alpha:0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color.withValues(alpha:0.35)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Icon(
                    status == _MarginStatus.below || status == _MarginStatus.low
                        ? Icons.warning_amber_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 14, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(message,
                    style: AppTextStyles.captionBold.copyWith(
                        color: color,
                        height: 1.4))),
              ]),
            ),
          ],
          const SizedBox(height: 16),

          // Boutons
          Row(children: [
            if (widget.item.customPrice != null)
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    widget.bloc.add(UpdateItemPrice(
                        widget.item.productId, null,
                        variantName: widget.item.variantName));
                    Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                    side: BorderSide(
                        color: Theme.of(context).semantic.borderSubtle),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(l.priceEditReset,
                      style: AppTextStyles.body
                          .copyWith(color: AppColors.textSecondary)),
                ),
              ),
            if (widget.item.customPrice != null) const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                // Toujours actif : une vente à perte (prix sous le coût) est
                // désormais AUTORISÉE après confirmation (déstockage).
                onPressed: _apply,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      AppColors.primary.withValues(alpha:0.35),
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(l.priceEditApply,
                    style: AppTextStyles.label.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
              ),
            ),
          ]),
        ]),
        ),
      ),
    );
  }
}

// ─── Widgets atomiques ────────────────────────────────────────────────────────
/// Puce de raccourci dans le sheet d'édition de prix (origine, -5%, -10%…).
/// Cible tactile ≥34px, style cohérent avec le bloc total (teinte primaire).
class _QuickPriceChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _QuickPriceChip({required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(20),
    child: Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      alignment: Alignment.center,
      child: Text(label,
          style: AppTextStyles.bodySmBold.copyWith(color: AppColors.primary)),
    ),
  );
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  /// Variante resserrée, utilisée par la ligne de panier RESTAURANT où le
  /// stepper partage sa ligne avec le nom, le prix et le sous-total.
  ///
  /// La taille par défaut n'est PAS réduite : elle avait été portée à 34/38 px
  /// précisément parce que 22 px passait sous le seuil ergonomique et générait
  /// des erreurs de tap. Un `dense` séparé évite de défaire ce correctif pour
  /// la caisse e-commerce.
  final bool dense;

  const _QtyBtn({
    required this.icon,
    required this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width < 900;
    final boxSize  = dense
        ? (isCompact ? 28.0 : 30.0)
        : (isCompact ? 34.0 : 38.0);
    final iconSize = dense
        ? (isCompact ? 15.0 : 16.0)
        : (isCompact ? 18.0 : 20.0);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: BoxConstraints(minWidth: boxSize, minHeight: boxSize),
        decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(isCompact ? 7 : 8),
            border: Border.all(
                color: Theme.of(context).semantic.borderSubtle)),
        child: Icon(icon, size: iconSize,
            color: Theme.of(context).colorScheme.onSurface),
      ),
    );
  }
}

class _FeeField extends StatelessWidget {
  final TextEditingController ctrl;
  final String hint;
  final IconData icon;
  final TextInputType inputType;
  const _FeeField({required this.ctrl, required this.hint,
    required this.icon, required this.inputType});
  @override
  Widget build(BuildContext context) => TextField(
    controller: ctrl,
    keyboardType: inputType,
    inputFormatters: inputType == TextInputType.number
        ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
        : null,
    style: AppTextStyles.body,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: AppTextStyles.bodySm
          .copyWith(color: AppColors.textHint),
      prefixIcon: Icon(icon, size: 16, color: AppColors.textHint),
      filled: true, fillColor: AppColors.inputFill, isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
              color: Theme.of(context).semantic.borderSubtle)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
              color: Theme.of(context).semantic.borderSubtle)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
    ),
  );
}

class _EmptyCart extends StatelessWidget {
  final AppLocalizations l;
  const _EmptyCart({required this.l});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.shopping_cart_outlined,
          size: 40, color: AppColors.divider),
      const SizedBox(height: 10),
      Text(l.caisseEmpty,
          style: AppTextStyles.body
              .copyWith(color: AppColors.textHint)),
    ]),
  );
}

// ─── Date de livraison prévue (cliquable, optionnel) ───────────────────────
// Représente la date que le client a demandée pour être livré.
// Persistée sur Sale.scheduledAt. La date RÉELLE de livraison (constatée
// au moment où la commande passe à `completed`) est saisie séparément dans
// le DeliveryDetailsSheet.
// ignore: unused_element
class _ScheduledDeliveryField extends StatelessWidget {
  final CaisseState state;
  const _ScheduledDeliveryField({required this.state});

  Future<void> _pickDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: state.deliveryDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('fr', 'FR'),
    );
    if (picked == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(state.deliveryDate
          ?? DateTime(picked.year, picked.month, picked.day, 14)),
    );
    if (!context.mounted) return;
    final date = DateTime(picked.year, picked.month, picked.day,
        time?.hour ?? 14, time?.minute ?? 0);
    context.read<CaisseBloc>().add(SetDeliveryDate(date));
  }

  String _format(DateTime d) {
    const days   = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin',
                    'juil', 'août', 'sep', 'oct', 'nov', 'déc'];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} · $h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final has = state.deliveryDate != null;
    return InkWell(
      onTap: () => _pickDate(context),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: has
              ? AppColors.primary.withValues(alpha:0.06)
              : AppColors.inputFill,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: has
                ? AppColors.primary.withValues(alpha:0.30)
                : Theme.of(context).semantic.borderSubtle,
          ),
        ),
        child: Row(children: [
          Icon(Icons.event_rounded,
              size: 16,
              color: has ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 8),
          Expanded(child: Text(
              has
                  ? 'Livraison prévue : ${_format(state.deliveryDate!)}'
                  : 'Date de livraison souhaitée (optionnel)',
              style: AppTextStyles.bodySm.copyWith(
                  fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                  color: has
                      ? AppColors.primary : AppColors.textSecondary))),
          if (has)
            InkWell(
              onTap: () =>
                  context.read<CaisseBloc>().add(SetDeliveryDate(null)),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded,
                    size: 14, color: AppColors.textHint),
              ),
            )
          else
            Icon(Icons.chevron_right_rounded,
                size: 16, color: AppColors.textHint),
        ]),
      ),
    );
  }
}

