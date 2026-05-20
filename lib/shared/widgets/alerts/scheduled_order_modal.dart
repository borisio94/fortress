import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/database/app_database.dart';
import '../../../core/i18n/app_localizations.dart';
import '../../../core/services/activity_log_service.dart';
import '../../../core/services/scheduled_order_alert_service.dart';
import '../../../core/storage/hive_boxes.dart';
import '../../../core/storage/local_storage_service.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/currency_formatter.dart';
import '../../../core/utils/duration_formatter.dart';
import '../../../features/caisse/domain/entities/sale.dart';
import '../../../features/parametres/presentation/widgets/transfer_form_sheet.dart';
import '../form_sheet.dart';

/// Modale plein écran NON-DISMISSIBLE déclenchée par
/// [ScheduledOrderAlertService] quand une (ou plusieurs) commande(s)
/// `scheduled` atteint un niveau ≥ CRITICAL.
///
/// Fonctionnalités :
///   * Compteur live (Timer 1s) `dans Xh Ymin` ou `depuis Xmin` (overdue).
///   * Pulsation du fond UNIQUEMENT pour le niveau MAX (CRITICAL = statique).
///   * Carrousel `PageView` si N>1 commandes en alerte simultanément.
///     Flèches ‹ › visibles uniquement ≥ 900px (desktop) ; sur mobile,
///     swipe horizontal natif du PageView.
///   * 3 actions : J'ai vu / Transférer au livreur / Annulée par le client.
///
/// Si la commande passe à `processing` / `cancelled` / `refused` après
/// transfert ou annulation, le listener `AppDatabase` du service appelle
/// `_purgeAcknowledgedForOrder` ET `evaluateAlerts()` re-émet sans la
/// commande clôturée → la modale se ferme via le caller (sprint 2B
/// observera `service.alerts` et fera `Navigator.pop` sur empty).
class ScheduledOrderModal extends StatefulWidget {
  final List<Sale> orders;
  final AlertLevel triggeringLevel;
  final VoidCallback? onDismissed;
  const ScheduledOrderModal({
    super.key,
    required this.orders,
    required this.triggeringLevel,
    this.onDismissed,
  });

  @override
  State<ScheduledOrderModal> createState() => _ScheduledOrderModalState();
}

class _ScheduledOrderModalState extends State<ScheduledOrderModal>
    with SingleTickerProviderStateMixin {
  late final PageController _pageCtrl;
  late final Timer _ticker;
  late AnimationController _pulseCtrl;
  int _index = 0;

  bool get _isMax => widget.triggeringLevel == AlertLevel.max;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController();
    // Pulsation visuelle uniquement pour MAX, pas CRITICAL (sinon trop
    // d'animation simultanée — fatigue visuelle).
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    if (_isMax) _pulseCtrl.repeat(reverse: true);
    // Ticker 1s pour rafraîchir le compteur live (dans Xmin / depuis Xmin).
    // Pas de setState par tick si pas monté.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    _pulseCtrl.dispose();
    _pageCtrl.dispose();
    widget.onDismissed?.call();
    super.dispose();
  }

  Sale get _current => widget.orders[_index];
  bool get _hasMany => widget.orders.length > 1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    return PopScope(
      canPop: false,
      child: Material(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600, maxHeight: 720),
            child: AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, child) {
                final t = _isMax ? _pulseCtrl.value : 0.0;
                final bg = Color.lerp(
                  sem.dangerSurface,
                  sem.danger.withValues(alpha: 0.25),
                  t,
                )!;
                return Container(
                  margin: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: sem.danger, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: sem.danger.withValues(alpha: 0.3),
                        blurRadius: 24, spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: child,
                );
              },
              child: _buildContent(context, theme, sem),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ThemeData theme,
      AppSemanticColors sem) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(context, sem),
        Expanded(
          child: _hasMany
              ? PageView.builder(
                  controller: _pageCtrl,
                  itemCount: widget.orders.length,
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (_, i) =>
                      _buildOrderBody(context, sem, widget.orders[i]),
                )
              : _buildOrderBody(context, sem, _current),
        ),
        _buildActions(context, sem),
        if (_hasMany) _buildCarouselNav(context, sem),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, AppSemanticColors sem) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded,
            color: sem.danger, size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            l.scheduledAlertModalTitle,
            style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w900,
              color: sem.dangerText, letterSpacing: 0.5),
          ),
        ),
        if (_hasMany)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: sem.danger,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              l.scheduledAlertCarouselIndicator(
                  _index + 1, widget.orders.length),
              style: const TextStyle(
                color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
      ]),
    );
  }

  Widget _buildOrderBody(BuildContext context, AppSemanticColors sem,
      Sale order) {
    final l = context.l10n;
    final delta = order.scheduledAt?.difference(DateTime.now()) ?? Duration.zero;
    final isOverdue = delta.isNegative;
    final formatted = DurationFormatter.compact(delta);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Compteur live ────────────────────────────────────────────
          Center(child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              Icon(isOverdue ? Icons.timer_off_rounded : Icons.timer_outlined,
                  color: sem.danger, size: 36),
              const SizedBox(height: 6),
              Text(
                isOverdue
                    ? l.scheduledAlertOverdueBy(formatted)
                    : l.scheduledAlertCountdown(formatted),
                style: TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w900,
                    color: sem.dangerText),
              ),
              if (order.scheduledAt != null) ...[
                const SizedBox(height: 2),
                Text(
                  _formatDateTime(order.scheduledAt!),
                  style: TextStyle(
                      fontSize: 13, color: sem.dangerText.withValues(alpha: 0.75)),
                ),
              ],
            ]),
          )),
          const SizedBox(height: 12),
          // ── Client ──────────────────────────────────────────────────
          _SectionLabel(label: 'Client', color: sem.dangerText),
          if ((order.clientName ?? '').isNotEmpty)
            Text(order.clientName!,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          if ((order.clientPhone ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.phone_rounded, size: 14, color: Colors.black54),
                const SizedBox(width: 4),
                Expanded(child: Text(order.clientPhone!,
                    style: const TextStyle(fontSize: 13))),
                _MiniIconBtn(
                  icon: Icons.call_rounded,
                  tooltip: 'Appeler',
                  onTap: () => _launch('tel:${order.clientPhone!}'),
                ),
                const SizedBox(width: 6),
                _MiniIconBtn(
                  icon: Icons.chat_rounded,
                  tooltip: 'WhatsApp',
                  onTap: () => _launch(
                      'https://wa.me/${_cleanPhone(order.clientPhone!)}'),
                ),
              ]),
            ),
          if (((order.deliveryAddress ?? '').isNotEmpty) ||
              ((order.deliveryCity ?? '').isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.place_outlined, size: 14, color: Colors.black54),
                const SizedBox(width: 4),
                Expanded(child: Text(
                  [order.deliveryAddress, order.deliveryCity]
                      .whereType<String>()
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  style: const TextStyle(fontSize: 13))),
              ]),
            ),
          if (order.deliveryMode != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Icon(Icons.local_shipping_outlined,
                    size: 14, color: Colors.black54),
                const SizedBox(width: 4),
                Text(order.deliveryMode!.labelFr,
                    style: const TextStyle(fontSize: 13)),
              ]),
            ),
          const SizedBox(height: 14),
          // ── Articles ────────────────────────────────────────────────
          _SectionLabel(
              label: 'Articles (${order.items.length})',
              color: sem.dangerText),
          ...order.items.map((it) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Text('${it.quantity}× ',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 13)),
                  Expanded(child: Text(
                    [it.productName, if ((it.variantName ?? '').isNotEmpty)
                        it.variantName!].join(' — '),
                    style: const TextStyle(fontSize: 13))),
                  Text(CurrencyFormatter.format(it.subtotal),
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ]),
              )),
          const Divider(height: 24),
          // ── Total ───────────────────────────────────────────────────
          Row(children: [
            Text('Total',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700,
                    color: sem.dangerText)),
            const Spacer(),
            Text(CurrencyFormatter.format(order.total),
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w900,
                    color: sem.dangerText)),
          ]),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, AppSemanticColors sem) {
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Wrap(
        spacing: 8, runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          ElevatedButton.icon(
            onPressed: () => _onAcknowledge(context),
            icon: const Icon(Icons.check_circle_rounded, size: 18),
            label: Text(l.scheduledAlertAcknowledge,
                style: const TextStyle(fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: sem.danger,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _onTransfer(context),
            icon: const Icon(Icons.swap_horiz_rounded, size: 18),
            label: Text(l.scheduledAlertTransferBtn,
                style: const TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: sem.dangerText,
              side: BorderSide(color: sem.danger),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _onCancelByClient(context),
            icon: const Icon(Icons.cancel_outlined, size: 18),
            label: Text(l.scheduledAlertCancelledByClient,
                style: const TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black87,
              side: const BorderSide(color: Colors.black26),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarouselNav(BuildContext context, AppSemanticColors sem) {
    // Flèches ‹ › visibles uniquement ≥ 900px (desktop). Mobile = swipe.
    final wide = MediaQuery.of(context).size.width >= 900;
    if (!wide) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        TextButton.icon(
          onPressed: _index > 0 ? _prev : null,
          icon: const Icon(Icons.chevron_left_rounded),
          label: const Text('Précédent'),
        ),
        const SizedBox(width: 16),
        TextButton.icon(
          onPressed: _index < widget.orders.length - 1 ? _next : null,
          label: const Text('Suivant'),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ]),
    );
  }

  // ══════════════════════════════════════════════════════════════════════
  //  ACTIONS
  // ══════════════════════════════════════════════════════════════════════

  Future<void> _onAcknowledge(BuildContext context) async {
    final navigator = Navigator.of(context); // capture avant await
    final id = _current.id;
    if (id != null) {
      await ScheduledOrderAlertService.instance
          .acknowledge(id, widget.triggeringLevel);
    }
    if (!mounted) return;
    if (_hasMany && _index < widget.orders.length - 1) {
      _next();
    } else {
      navigator.pop();
    }
  }

  Future<void> _onTransfer(BuildContext context) async {
    final user = LocalStorageService.getCurrentUser();
    if (user == null) return;
    // La sheet existante s'occupe de l'UX transfert. Si le transfert réussit,
    // le statut commande passera à processing → AppDatabase listener purge
    // automatiquement les ack et la modale se fermera au prochain
    // evaluateAlerts (le caller observe le Stream).
    final shopId = _current.shopId;
    final loc = AppDatabase.getShopLocation(shopId);
    await showFormSheet<bool>(
      context: context,
      builder: (_) => TransferFormSheet(
        ownerId:        user.id,
        presetSourceId: loc?.id,
      ),
    );
  }

  Future<void> _onCancelByClient(BuildContext context) async {
    final navigator = Navigator.of(context); // capture avant await
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Marquer comme annulée ?'),
        content: const Text(
            'Marquer cette commande comme annulée par le client ? '
            'Cette action est tracée.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Annuler')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(ctx).semantic.danger,
                foregroundColor: Colors.white),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Oui, annuler la commande')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final id = _current.id;
    if (id == null) return;
    try {
      // Lecture map originale pour préserver tous les champs non couverts
      // par SaleModel (deliveryAddress etc.) — on ne fait que muter status.
      final raw = HiveBoxes.ordersBox.get(id) ??
          (throw Exception('Commande introuvable en local'));
      final map = Map<String, dynamic>.from(raw);
      map['status'] = 'cancelled';
      await HiveBoxes.ordersBox.put(id, map);
      AppDatabase.bgWriteOrder(map);
      AppDatabase.notifyOrderChange(_current.shopId);
      // Audit trail — pattern cohérent avec les autres acquittements critiques.
      await ActivityLogService.log(
        action:      'order_cancelled_by_client_from_alert',
        targetType:  'order',
        targetId:    id,
        targetLabel: _current.clientName,
        shopId:      _current.shopId,
        details:     {'level': widget.triggeringLevel.name},
      );
    } catch (e) {
      debugPrint('[ScheduledOrderModal] cancel error: $e');
    }
    if (!mounted) return;
    if (_hasMany && _index < widget.orders.length - 1) {
      _next();
    } else {
      navigator.pop();
    }
  }

  void _prev() => _pageCtrl.previousPage(
      duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  void _next() => _pageCtrl.nextPage(
      duration: const Duration(milliseconds: 250), curve: Curves.easeOut);

  Future<void> _launch(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[ScheduledOrderModal] launch failed: $e');
    }
  }

  String _cleanPhone(String raw) =>
      raw.replaceAll(RegExp(r'[\s\-\.\+\(\)]'), '');

  String _formatDateTime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)} — '
        '${two(dt.day)}/${two(dt.month)}/${dt.year}';
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final Color color;
  const _SectionLabel({required this.label, required this.color});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w800,
              letterSpacing: 0.6, color: color.withValues(alpha: 0.85)),
        ),
      );
}

class _MiniIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _MiniIconBtn({
    required this.icon, required this.tooltip, required this.onTap});
  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: tooltip,
        icon: Icon(icon, size: 18),
        onPressed: onTap,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      );
}

/// Helper d'ouverture standardisé. Utilise `showDialog` plutôt qu'un sheet
/// car la modal doit couvrir tout l'écran et ne pas être dismiss par swipe.
Future<void> showScheduledOrderModal(
  BuildContext context, {
  required List<Sale> orders,
  required AlertLevel triggeringLevel,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.transparent, // déjà géré par le Material du modal
    builder: (_) => ScheduledOrderModal(
      orders:          orders,
      triggeringLevel: triggeringLevel,
    ),
  );
}
