import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/daily_menu_service.dart';
import '../../../../core/services/invoice_printer.dart';
import '../../../../core/services/manager_gate.dart';
import '../../../../core/services/payment_service.dart';
import '../../../../core/services/restaurant_order_service.dart';
import '../../../../core/services/restaurant_table_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/duration_formatter.dart';
import '../../../../features/caisse/domain/entities/sale.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/restaurant_table.dart';
import '../widgets/deposit_sheet.dart';
import '../widgets/packaging_sheet.dart';
import '../widgets/payment_sheet.dart';

/// Addition d'une table : récapitulatif, partage entre convives et
/// encaissement (module restaurant, PR-3).
///
/// UI dédiée au service en salle. L'encaissement lui-même délègue à la
/// couche données partagée (`updateOrderStatus` via
/// [RestaurantOrderService.settleAndRelease]), qui porte déjà le verrou de
/// transitions, le décrément de stock et le statut de paiement.
class BillPage extends ConsumerStatefulWidget {
  final String shopId;
  final String tableId;

  const BillPage({
    super.key,
    required this.shopId,
    required this.tableId,
  });

  @override
  ConsumerState<BillPage> createState() => _BillPageState();
}

class _BillPageState extends ConsumerState<BillPage> {
  RestaurantTable? _table;
  Sale? _order;

  /// Nombre de parts pour le partage. 1 = pas de partage.
  int _shares = 1;

  bool _settling = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final table = RestaurantTableService.tableById(widget.tableId);
    if (table == null) return;
    final order = RestaurantOrderService.currentOrderFor(table);
    setState(() {
      _table = table;
      _order = order;
      _shares = 1;
    });
  }

  double get _total => _order?.total ?? 0;

  /// Ajoute une consigne d'emballages à l'addition (Lot B).
  ///
  /// Pas de PIN : la consigne AUGMENTE le montant dû, elle ne fait pas sortir
  /// d'argent. C'est le retour (ou la perte) qui se contrôle, depuis le hub
  /// Emballe des RESTES de fin de repas.
  ///
  /// À la demande, jamais d'office : sur place l'emballage est l'exception, et
  /// imposer cette feuille à chaque encaissement ralentirait tout le service
  /// pour un cas minoritaire.
  Future<void> _addPackaging() async {
    final order = _order;
    if (order == null) return;
    final billed = await showPackagingSheet(
      context: context,
      shopId: widget.shopId,
      order: order,
      isLeftovers: true,
    );
    if (billed == null || !mounted) return;
    // Relecture : les lignes de frais viennent d'être écrites, le total
    // affiché doit les refléter AVANT l'encaissement.
    _load();
    if (billed > 0) {
      AppSnack.success(
          context, '$billed emballage(s) ajouté(s) — stock déduit');
    }
  }

  /// Finances.
  Future<void> _addDeposit() async {
    final order = _order;
    final table = _table;
    if (order == null) return;
    final deposit = await showDepositSheet(
      context: context,
      shopId: widget.shopId,
      order: order,
      holder: '${table?.name ?? 'Table'}'
          '${(order.tabLabel ?? '').isEmpty ? '' : ' · ${order.tabLabel}'}',
    );
    if (deposit == null || !mounted) return;
    // Relecture : la ligne de frais vient d'être écrite sur la commande, le
    // total affiché doit la refléter avant l'encaissement.
    _load();
    AppSnack.success(
        context,
        '${deposit.quantity} × ${deposit.label} consigné'
        '${deposit.quantity > 1 ? 's' : ''} — '
        '${CurrencyFormatter.format(deposit.totalAmount.toDouble())}');
  }

  /// Applique une remise sur l'addition, sous aval du gérant.
  ///
  /// Sous PIN parce que c'est l'autre façon de faire sortir de l'argent sans
  /// qu'un plat sorte : remiser après encaissement, et garder la différence.
  Future<void> _discount() async {
    final order = _order;
    if (order == null) return;

    final res = await showAdaptiveFormSheet<({double amount, String reason})>(
      context: context,
      builder: (_) => _DiscountSheet(
        subtotal: order.subtotal,
        current: order.discountAmount,
      ),
    );
    if (res == null || !mounted) return;

    final ok = await ManagerGate.require(
      context: context,
      perms: ref.read(permissionsProvider(widget.shopId)),
      action: ManagerAction.discountBill,
      shopId: widget.shopId,
      targetId: order.id,
      targetLabel: _table?.name,
      details: {
        'amount': res.amount,
        'reason': res.reason,
        'subtotal': order.subtotal,
      },
    );
    if (!ok || !mounted) return;

    await RestaurantOrderService.applyDiscount(order, res.amount);
    if (!mounted) return;
    _load();
    AppSnack.success(
        context,
        res.amount <= 0
            ? 'Remise retirée.'
            : 'Remise de ${CurrencyFormatter.format(res.amount)} appliquée.');
  }

  Future<void> _settle() async {
    final table = _table;
    final order = _order;
    if (table == null || order == null) return;

    // Reste dû = total − ce qui a déjà été encaissé (acompte). Arrondi à
    // l'unité : le FCFA n'a pas de centimes, et un reste de 0,4 F empêcherait
    // l'addition de tomber juste.
    final due = (order.total - order.amountPaid).round();
    final split = await showAdaptiveFormSheet<PaymentSplit>(
      context: context,
      builder: (_) => PaymentSheet(
        due: due < 0 ? 0 : due,
        subtitle: '${table.name}'
            '${(order.tabLabel ?? '').isEmpty ? '' : ' · ${order.tabLabel}'}',
      ),
    );
    if (split == null || !mounted) return;

    setState(() => _settling = true);
    try {
      final res = await RestaurantOrderService.settleAndRelease(
        order: order,
        table: table,
        // Addition soldée → `null` force « entièrement payé » et absorbe les
        // décimales d'un total non entier. Sinon on transmet l'encaissé réel,
        // qui laisse la différence en créance client.
        amountPaid: split.isSettled
            ? null
            : (order.amountPaid + split.applied),
        method: split.dominantMethod,
      );
      final settled = res.order;
      if (!mounted) return;

      // Règlements enregistrés APRÈS la clôture : si `settleAndRelease` lève
      // (transition interdite, stock insuffisant), aucune ligne de paiement ne
      // doit rester derrière une addition non encaissée.
      final orderId = order.id;
      if (orderId != null && orderId.isNotEmpty) {
        await PaymentService.recordSplit(
          shopId: widget.shopId,
          orderId: orderId,
          split: split,
        );
      }
      if (!mounted) return;
      AppSnack.success(
          context,
          split.change > 0
              ? '${table.name} encaissée — rendre '
                  '${CurrencyFormatter.format(split.change.toDouble())}'
              : '${table.name} encaissée et libérée');

      // APRÈS le succès : l'addition est réglée, la table libérée. Ce qui suit
      // avertit que la réserve ne correspond plus au décompte du jour — un
      // dépassement, ou une écriture que Hive a refusée. Sans ça, le serveur
      // ne l'apprenait qu'au prochain inventaire, sans pouvoir le rattacher à
      // une vente.
      final warn = oversoldMessage(res.stock, order.items);
      if (warn != null && mounted) AppSnack.warning(context, warn);

      // Facture générée automatiquement après encaissement (spec §7).
      if (settled != null) {
        final shop = LocalStorageService.getShop(widget.shopId);
        await InvoicePrinter.printOrShare(
          context: context,
          sale: settled,
          shop: shop,
        );
      }
      if (mounted) context.pop();
    } catch (e) {
      // Remonte tel quel : `updateOrderStatus` lève des exceptions métier
      // explicites (transition interdite, motif requis) dont le message est
      // déjà rédigé pour l'utilisateur.
      if (mounted) AppSnack.error(context, e.toString());
    } finally {
      if (mounted) setState(() => _settling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final table = _table;
    final order = _order;

    if (table == null) {
      return AppScaffold(
        shopId: widget.shopId,
        title: 'Addition',
        isRootPage: false,
        body: const Center(child: Text('Table introuvable.')),
      );
    }
    if (order == null || order.items.isEmpty) {
      return AppScaffold(
        shopId: widget.shopId,
        title: 'Addition — ${table.name}',
        isRootPage: false,
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Aucune commande en cours sur cette table.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Addition — ${table.name}',
      isRootPage: false,
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _TableInfoCard(table: table, order: order),
                const SizedBox(height: 16),
                _ItemsCard(order: order),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      onPressed: _settling ? null : _addPackaging,
                      icon: const Icon(Icons.takeout_dining_outlined, size: 18),
                      label: const Text('Restes'),
                    ),
                    TextButton.icon(
                      onPressed: _settling ? null : _addDeposit,
                      icon: const Icon(Icons.liquor_outlined, size: 18),
                      label: const Text('Consigne'),
                    ),
                    TextButton.icon(
                      onPressed: _settling ? null : _discount,
                      icon: const Icon(Icons.percent_rounded, size: 18),
                      label: Text(order.discountAmount > 0
                          ? 'Modifier la remise'
                          : 'Remise'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _SplitCard(
                  total: _total,
                  covers: order.covers ?? table.capacity,
                  shares: _shares,
                  onSharesChanged: (v) => setState(() => _shares = v),
                ),
              ],
            ),
          ),
          _SettleBar(
            total: _total,
            busy: _settling,
            onSettle: _settle,
          ),
        ],
      ),
    );
  }
}

/// En-tête : couverts, serveur, durée du repas.
class _TableInfoCard extends StatelessWidget {
  final RestaurantTable table;
  final Sale order;

  const _TableInfoCard({required this.table, required this.order});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    final duration = RestaurantOrderService.mealDuration(table, order);
    final server = order.createdByUserId;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        children: [
          _row(context, Icons.tag_rounded, 'Table', table.name),
          _row(context, Icons.people_rounded, 'Couverts',
              '${order.covers ?? table.covers ?? 1}'),
          if (duration != null)
            _row(context, Icons.access_time_rounded, 'Durée du repas',
                DurationFormatter.compact(duration)),
          if (server != null && server.isNotEmpty)
            _row(context, Icons.person_outline_rounded, 'Serveur', server),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, IconData icon, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Text(label, style: AppTextStyles.captionHint),
          const Spacer(),
          Text(value, style: AppTextStyles.bodySmBold),
        ],
      ),
    );
  }
}

/// Détail des articles consommés.
class _ItemsCard extends StatelessWidget {
  final Sale order;
  const _ItemsCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Détail', style: AppTextStyles.bodyBold),
          const SizedBox(height: 8),
          for (final item in order.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${item.quantity}×', style: AppTextStyles.bodySmBold),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.productName, style: AppTextStyles.bodySm),
                        if (item.modifiersLabel.isNotEmpty)
                          Text(item.modifiersLabel,
                              style: AppTextStyles.micro.copyWith(
                                  color: semantic.warning)),
                      ],
                    ),
                  ),
                  Text(CurrencyFormatter.format(item.subtotal),
                      style: AppTextStyles.bodySm),
                ],
              ),
            ),
          // Remise accordée par le gérant (geste sous PIN) : affichée en
          // clair sur l'addition, le client doit pouvoir la lire.
          if (order.discountAmount > 0) ...[
            const Divider(height: 18),
            Row(
              children: [
                const Expanded(
                    child: Text('Remise', style: AppTextStyles.bodySm)),
                Text('− ${CurrencyFormatter.format(order.discountAmount)}',
                    style: AppTextStyles.bodySm
                        .copyWith(color: semantic.success)),
              ],
            ),
          ],
          // Frais éventuels (la commande partage le modèle de la caisse).
          if (order.totalFees > 0) ...[
            const Divider(height: 18),
            Row(
              children: [
                const Expanded(
                    child: Text('Frais', style: AppTextStyles.bodySm)),
                Text(CurrencyFormatter.format(order.totalFees),
                    style: AppTextStyles.bodySm),
              ],
            ),
          ],
          const Divider(height: 18),
          Row(
            children: [
              const Expanded(
                  child: Text('Total', style: AppTextStyles.subtitleBold)),
              Text(CurrencyFormatter.format(order.total),
                  style: AppTextStyles.subtitleBold),
            ],
          ),
        ],
      ),
    );
  }
}

/// Partage de l'addition entre convives.
class _SplitCard extends StatelessWidget {
  final double total;
  final int covers;
  final int shares;
  final ValueChanged<int> onSharesChanged;

  const _SplitCard({
    required this.total,
    required this.covers,
    required this.shares,
    required this.onSharesChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final semantic = theme.semantic;
    // Bornes : de 2 parts jusqu'au nombre de couverts (spec). Au minimum 2
    // options proposées même pour une table d'une personne, sinon la carte
    // n'aurait aucun intérêt.
    final maxShares = covers < 2 ? 2 : covers;
    final perPerson = RestaurantOrderService.splitAmount(total, shares);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: semantic.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Partager l\'addition', style: AppTextStyles.bodyBold),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(context, label: 'Non', value: 1),
              for (var n = 2; n <= maxShares; n++)
                _chip(context, label: '÷ $n', value: n),
            ],
          ),
          if (shares > 1) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text('$shares × ', style: AppTextStyles.bodySecondary),
                Text(CurrencyFormatter.format(perPerson),
                    style: AppTextStyles.subtitleBold
                        .copyWith(color: theme.colorScheme.primary)),
                const Spacer(),
                Text('par personne', style: AppTextStyles.captionHint),
              ],
            ),
            // L'arrondi supérieur fait que N parts peuvent dépasser le total :
            // on l'affiche pour que le serveur sache combien il rend.
            if (perPerson * shares > total)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Soit ${CurrencyFormatter.format(perPerson * shares)} '
                  'encaissés — ${CurrencyFormatter.format(perPerson * shares - total)} '
                  'à rendre.',
                  style: AppTextStyles.micro
                      .copyWith(color: semantic.warning),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context,
      {required String label, required int value}) {
    final theme = Theme.of(context);
    final sel = shares == value;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      onSelected: (_) => onSharesChanged(value),
      labelStyle: AppTextStyles.bodySm.copyWith(
        color: sel ? theme.colorScheme.primary : null,
        fontWeight: sel ? FontWeight.w600 : FontWeight.w500,
      ),
    );
  }
}

/// Saisie d'une remise sur l'addition : montant + motif obligatoire.
///
/// Deux entrées pour un même geste — un montant en francs, ou un pourcentage
/// converti immédiatement. Le serveur annonce « 10 % » au client, le gérant
/// raisonne en francs sur la marge : les deux doivent tomber sur la même
/// valeur sans calcul mental.
class _DiscountSheet extends StatefulWidget {
  final double subtotal;
  final double current;

  const _DiscountSheet({required this.subtotal, required this.current});

  @override
  State<_DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends State<_DiscountSheet> {
  late final _amount = TextEditingController(
      text: widget.current <= 0 ? '' : '${widget.current.round()}');
  final _reason = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  double get _value =>
      double.tryParse(_amount.text.trim().replaceAll(' ', '')) ?? 0;

  void _setPercent(int p) => setState(() {
        _amount.text = '${(widget.subtotal * p / 100).round()}';
        _err = null;
      });

  void _submit() {
    final v = _value;
    if (v < 0) {
      setState(() => _err = 'Montant invalide');
      return;
    }
    if (v > widget.subtotal) {
      // Plafonné aussi côté service, mais le dire ici évite au gérant de
      // valider un geste qui sera silencieusement rogné.
      setState(() => _err = 'La remise ne peut pas dépasser le montant des '
          'articles (${CurrencyFormatter.format(widget.subtotal)}).');
      return;
    }
    if (_reason.text.trim().isEmpty) {
      setState(() => _err = 'Motif obligatoire');
      return;
    }
    Navigator.of(context).pop((amount: v, reason: _reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Remise sur l\'addition',
      subtitle: 'Articles : ${CurrencyFormatter.format(widget.subtotal)}',
      icon: Icons.percent_rounded,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Une validation du gérant est demandée.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 10),
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(),
              decoration: const InputDecoration(
                labelText: 'Montant de la remise',
                hintText: '0 pour retirer la remise',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final p in [5, 10, 15, 20])
                  ActionChip(
                      label: Text('$p %'), onPressed: () => _setPercent(p)),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _reason,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Motif',
                hintText: 'Geste commercial, attente en cuisine…',
              ),
              onSubmitted: (_) => _submit(),
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Valider la remise',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _submit,
            ),
          ],
        ),
      ),
    );
  }
}

/// Barre d'encaissement épinglée en bas.
class _SettleBar extends StatelessWidget {
  final double total;
  final bool busy;
  final VoidCallback onSettle;

  const _SettleBar({
    required this.total,
    required this.busy,
    required this.onSettle,
  });

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).semantic;
    return Container(
      decoration: BoxDecoration(
        color: semantic.elevatedSurface,
        border: Border(top: BorderSide(color: semantic.borderSubtle)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: AppPrimaryButton(
            label: 'Encaisser ${CurrencyFormatter.format(total)}',
            icon: Icons.check_circle_outline_rounded,
            fullWidth: true,
            isLoading: busy,
            onTap: onSettle,
          ),
        ),
      ),
    );
  }
}
