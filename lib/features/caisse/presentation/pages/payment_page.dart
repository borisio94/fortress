import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/database/app_database.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/invoice_storage_service.dart';
import '../../../../core/services/url_shortener_service.dart';
import '../../../../core/services/whatsapp/message_templates.dart';
import '../../../../core/services/whatsapp_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../../parametres/data/shop_settings_store.dart';
import 'package:printing/printing.dart';
import '../../domain/entities/sale.dart';
import '../../domain/usecases/order_receipt_usecase.dart';
import '../bloc/caisse_bloc.dart';
import '../widgets/post_sale_sheet.dart';
import '../widgets/delivery_details_sheet.dart';

class PaymentPage extends StatelessWidget {
  final String shopId;
  const PaymentPage({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) {
    return BlocListener<CaisseBloc, CaisseState>(
      listenWhen: (prev, curr) =>
          !prev.saleCompleted && curr.saleCompleted && curr.lastCompletedSale != null,
      listener: (context, state) {
        // Naviguer vers l'écran de succès
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => _SuccessScreen(
            sale: state.lastCompletedSale!,
            shopId: shopId,
            onNewSale: () {
              context.read<CaisseBloc>().add(ClearCart());
              context.go('/shop/$shopId/caisse');
            },
          )),
        );
      },
      child: _PaymentView(shopId: shopId),
    );
  }
}

// ═══════════���═════════════════════════════════════════════════════════════════
// VUE PAIEMENT — choix du mode + confirmation
// ══════���════════════════════���═════════════════════════════════════════════════

class _PaymentView extends StatelessWidget {
  final String shopId;
  const _PaymentView({required this.shopId});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AppScaffold(
      shopId: shopId, title: l.boutiquePay, isRootPage: false,
      body: BlocBuilder<CaisseBloc, CaisseState>(
        builder: (context, state) {
          if (state.items.isEmpty) {
            return Center(child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.shopping_cart_outlined,
                    size: 48, color: Color(0xFFD1D5DB)),
                const SizedBox(height: 12),
                const Text('Panier vide',
                    style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('Retour à la caisse'),
                ),
              ],
            ));
          }

          return ListView(padding: const EdgeInsets.all(20), children: [

            // ── Récap montant ─────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
                    blurRadius: 8, offset: const Offset(0, 2))],
              ),
              child: Column(children: [
                Text(l.boutiqueTotal,
                    style: const TextStyle(fontSize: 13,
                        color: Color(0xFF6B7280))),
                const SizedBox(height: 8),
                Text(CurrencyFormatter.format(state.total),
                    style: TextStyle(fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary)),
                const SizedBox(height: 12),
                const Divider(color: Color(0xFFF0F0F0)),
                const SizedBox(height: 8),
                _SummaryLine('Sous-total',
                    CurrencyFormatter.format(state.subtotal)),
                if (state.totalFees > 0) ...[
                  const SizedBox(height: 4),
                  _SummaryLine('Frais',
                      CurrencyFormatter.format(state.totalFees)),
                ],
                if (state.discountAmount > 0) ...[
                  const SizedBox(height: 4),
                  _SummaryLine('Remise',
                      '- ${CurrencyFormatter.format(state.discountAmount)}',
                      color: const Color(0xFFF59E0B)),
                ],
                if (state.taxAmount > 0) ...[
                  const SizedBox(height: 4),
                  _SummaryLine('TVA (${state.taxRate.toStringAsFixed(state.taxRate % 1 == 0 ? 0 : 1)}%)',
                      CurrencyFormatter.format(state.taxAmount)),
                ],
                const SizedBox(height: 4),
                Text('${state.itemCount} article${state.itemCount > 1 ? 's' : ''}',
                    style: const TextStyle(fontSize: 11,
                        color: Color(0xFF9CA3AF))),
              ]),
            ),
            const SizedBox(height: 24),

            // Le mode de paiement est maintenant capturé dans le sheet
            // "Détails de livraison" qui s'ouvre à la confirmation, en même
            // temps que le mode de livraison et les détails d'expédition.

            // ── Bouton confirmer ──────────────────────────────────
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton(
                onPressed: state.isProcessing
                    ? null
                    : () async {
                        HapticFeedback.mediumImpact();
                        // P0-5 : refuser la vente si le membership de
                        // l'employé n'est plus actif (suspendu/archivé).
                        // Sinon Supabase rejetterait silencieusement la
                        // sync et la vente resterait bloquée en queue.
                        final uid = Supabase.instance.client
                            .auth.currentUser?.id;
                        if (uid != null
                            && !AppDatabase.canActInShop(uid, shopId)) {
                          AppSnack.error(context,
                              'Votre compte est suspendu sur cette '
                              'boutique. Contactez le propriétaire.');
                          return;
                        }
                        // Capturer mode de paiement + livraison/expédition
                        // AVANT de compléter la vente : le stock sera déduit
                        // de la bonne source et la commande embarque tous
                        // les champs (paiement, ville, adresse, agence…).
                        final res = await showDeliveryDetailsSheet(
                          context,
                          shopId: shopId,
                          initialPaymentMethod: state.paymentMethod,
                        );
                        if (res == null) return; // annulé
                        if (!context.mounted) return;
                        context.read<CaisseBloc>()
                          ..add(SelectPaymentMethod(res.paymentMethod))
                          ..add(SetDeliveryDetails(
                            mode:            res.mode,
                            locationId:      res.locationId,
                            personName:      res.personName,
                            deliveryCity:    res.deliveryCity,
                            deliveryAddress: res.deliveryAddress,
                            shipmentCity:    res.shipmentCity,
                            shipmentAgency:  res.shipmentAgency,
                            shipmentHandler: res.shipmentHandler,
                            date:            res.date,
                          ))
                          ..add(CompleteSale(shopId));
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: state.isProcessing
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Row(mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.check_circle_rounded, size: 20),
                          const SizedBox(width: 8),
                          Text('Confirmer ${CurrencyFormatter.format(state.total)}',
                              style: const TextStyle(fontSize: 15,
                                  fontWeight: FontWeight.w700)),
                        ]),
              ),
            ),

            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(state.error!,
                  style: const TextStyle(fontSize: 12,
                      color: Color(0xFFEF4444)),
                  textAlign: TextAlign.center),
            ],
          ]);
        },
      ),
    );
  }

}

class _SummaryLine extends StatelessWidget {
  final String label, value;
  final Color? color;
  const _SummaryLine(this.label, this.value, {this.color});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(label, style: TextStyle(fontSize: 12,
          color: color ?? const Color(0xFF6B7280))),
      Text(value, style: TextStyle(fontSize: 12,
          fontWeight: FontWeight.w600,
          color: color ?? const Color(0xFF374151))),
    ],
  );
}

// ═══════════════════════════════════════════════════════════════��═════════════
// ÉCRAN DE SUCCÈS — après validation de la vente
// ═══════════════════════════════════════════════���═════════════════════════════

class _SuccessScreen extends ConsumerStatefulWidget {
  final Sale sale;
  final String shopId;
  final VoidCallback onNewSale;
  const _SuccessScreen({
    required this.sale, required this.shopId, required this.onNewSale});
  @override
  ConsumerState<_SuccessScreen> createState() => _SuccessScreenState();
}

class _SuccessScreenState extends ConsumerState<_SuccessScreen> {
  bool _sendingInvoice = false;

  @override
  void initState() {
    super.initState();
    // Ouvrir automatiquement le bottom sheet d'envoi du reçu
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) PostSaleSheet.show(context, widget.sale);
    });
  }

  /// Génère le PDF facture, l'upload sur Supabase Storage (bucket privé
  /// `factures`) et ouvre WhatsApp avec un message pré-rempli contenant
  /// la signed URL valide 30 jours. Le numéro client de la `Sale` est
  /// pré-rempli si disponible.
  Future<void> _sendInvoiceWhatsApp() async {
    final sale = widget.sale;
    final phone = sale.clientPhone ?? '';
    if (phone.trim().isEmpty) {
      AppSnack.error(context,
          'Numéro WhatsApp du client manquant — '
          'ajoute-le dans la fiche client puis réessaie.');
      return;
    }
    setState(() => _sendingInvoice = true);
    try {
      // 1. Génération PDF (réutilisation du DocumentService existant
      //    via OrderReceiptUseCase qui produit un Uint8List).
      final shop = LocalStorageService.getShop(sale.shopId);
      final bytes = await OrderReceiptUseCase.generatePdf(sale, shop: shop);

      // 2. Upload + signed URL 30 jours.
      final orderId = sale.id ?? 'order_${sale.createdAt.millisecondsSinceEpoch}';
      final longUrl = await InvoiceStorageService.uploadInvoice(
        shopId: sale.shopId,
        orderId: orderId,
        bytes: bytes,
      );
      if (longUrl == null) {
        if (mounted) {
          AppSnack.error(context,
              'Upload de la facture échoué. Vérifie ta connexion '
              'puis réessaie.');
        }
        return;
      }

      // 3. Raccourcir l'URL signée (fallback silencieux à l'URL longue).
      final shortUrl = await UrlShortenerService.shorten(longUrl);

      // 4. Style de message lu depuis les paramètres boutique (Hive).
      final styleKey = ShopSettingsStore(sale.shopId)
          .read<String>('whatsapp_message_style', fallback: 'standard');
      final style = WhatsappMessageStyleX.fromKey(styleKey);

      // 5. Construction du message via les templates centralisés.
      final msg = MessageTemplates.buildMessage(
        order:    sale,
        shop:     shop,
        shortUrl: shortUrl,
        style:    style,
      );

      // 6. Numéro normalisé pour wa.me (chiffres seulement, indicatif inclus).
      final wamePhone = PhoneFormatter.toWame(phone);
      final ok = await ref.read(whatsappServiceProvider)
          .sendMessage(wamePhone, msg);
      if (!ok && mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. La facture est uploadée — '
            'tu peux copier-coller manuellement le lien.');
      }
    } catch (e) {
      if (mounted) {
        AppSnack.error(context, 'Erreur envoi facture : $e');
      }
    } finally {
      if (mounted) setState(() => _sendingInvoice = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sale = widget.sale;
    final shopId = widget.shopId;
    final onNewSale = widget.onNewSale;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(children: [
            const Spacer(flex: 2),

            // ── Icône succès animée ──────────────────────────────
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 600),
              curve: Curves.elasticOut,
              builder: (_, scale, child) => Transform.scale(
                  scale: scale, child: child),
              child: Container(
                width: 80, height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981).withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_rounded,
                    size: 40, color: Color(0xFF10B981)),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Vente encaissée !',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A))),
            const SizedBox(height: 6),
            Text(CurrencyFormatter.format(sale.total),
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800,
                    color: AppColors.primary)),
            const SizedBox(height: 4),
            Text(_paymentLabel(sale.paymentMethod),
                style: const TextStyle(fontSize: 13,
                    color: Color(0xFF6B7280))),
            if (sale.clientName != null) ...[
              const SizedBox(height: 4),
              Text('Client : ${sale.clientName}',
                  style: const TextStyle(fontSize: 12,
                      color: Color(0xFF9CA3AF))),
            ],

            const Spacer(),

            // ── Imprimer ticket caisse (80mm) ─────────────────────
            SizedBox(
              width: double.infinity, height: 48,
              child: ElevatedButton.icon(
                onPressed: () => _printTicket(context, sale),
                icon: const Icon(Icons.print_rounded, size: 18),
                label: const Text('Imprimer le ticket',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary.withOpacity(0.10),
                  foregroundColor: AppColors.primary,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ── Envoyer la facture par WhatsApp (wa.me) ───────────
            SizedBox(
              width: double.infinity, height: 48,
              child: ElevatedButton.icon(
                onPressed: _sendingInvoice ? null : _sendInvoiceWhatsApp,
                icon: _sendingInvoice
                    ? const SizedBox(width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(
                    _sendingInvoice
                        ? 'Préparation de la facture…'
                        : 'Envoyer la facture (WhatsApp)',
                    style: const TextStyle(fontSize: 14,
                        fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF25D366),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ── Envoi du reçu (share sheet multi-canal) ───────────
            SizedBox(
              width: double.infinity, height: 48,
              child: OutlinedButton.icon(
                onPressed: () => PostSaleSheet.show(context, sale),
                icon: const Icon(Icons.receipt_long_rounded, size: 18),
                label: const Text('Envoyer le reçu',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: BorderSide(color: AppColors.primary.withOpacity(0.4)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Nouvelle vente ────────────────────────────────────
            SizedBox(
              width: double.infinity, height: 50,
              child: ElevatedButton.icon(
                onPressed: onNewSale,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Nouvelle vente',
                    style: TextStyle(fontSize: 15,
                        fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go('/shop/$shopId/dashboard'),
              child: const Text('Retour au dashboard',
                  style: TextStyle(fontSize: 13,
                      color: Color(0xFF6B7280))),
            ),

            const Spacer(),
          ]),
        ),
      ),
    );
  }

  static String _paymentLabel(PaymentMethod m) => switch (m) {
    PaymentMethod.cash        => 'Espèces',
    PaymentMethod.mobileMoney => 'Mobile Money',
    PaymentMethod.card        => 'Carte bancaire',
    PaymentMethod.credit      => 'Crédit',
  };

  /// Imprime un ticket caisse au format 80mm (rouleau standard).
  /// Le système Print de l'OS s'ouvre — sur PC il propose les imprimantes
  /// classiques + PDF ; sur mobile il propose les imprimantes thermiques
  /// connectées.
  static Future<void> _printTicket(BuildContext context, Sale sale) async {
    try {
      await Printing.layoutPdf(
        name: 'Ticket-${sale.id}',
        format: PdfPageFormat.roll80,
        onLayout: (format) async => OrderReceiptUseCase.generatePdf(
            sale, pageFormat: format),
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur impression : $e')),
        );
      }
    }
  }
}
