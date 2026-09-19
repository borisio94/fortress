import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/fortress_logo.dart';

/// Page publique de suivi de commande — accessible sans authentification via
/// `/track/<order_id>`. Le lien est inséré dans le message WhatsApp de
/// relance envoyé au client.
///
/// Affiche :
///   - Nom de la boutique
///   - Numéro de commande, date de livraison, statut
///   - Liste des produits commandés (depuis `orders.items` JSONB)
///   - Total
///   - Bouton « Valider ma commande » : appelle la RPC
///     `validate_order_by_client` qui bascule status `scheduled` → `processing`.
///   - Lien « Voir le catalogue » → `/catalogue/<shop_id>` avec hint pour
///     commander directement d'autres produits.
///
/// Lecture via la RPC `get_tracked_order` (SECURITY DEFINER) — pas de
/// SELECT direct sur `orders` côté anon (évite tout listing).
class OrderTrackingPage extends StatefulWidget {
  final String orderId;
  const OrderTrackingPage({super.key, required this.orderId});

  @override
  State<OrderTrackingPage> createState() => _OrderTrackingPageState();
}

class _OrderTrackingPageState extends State<OrderTrackingPage> {
  late Future<_TrackedOrder> _future;
  bool _validating = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_TrackedOrder> _load() async {
    final db = Supabase.instance.client;
    final res = await db.rpc('get_tracked_order',
        params: {'p_order_id': widget.orderId});
    if (res == null) {
      throw Exception('Commande introuvable.');
    }
    final m = Map<String, dynamic>.from(res as Map);
    return _TrackedOrder.fromMap(m);
  }

  Future<void> _validate() async {
    setState(() => _validating = true);
    try {
      final db = Supabase.instance.client;
      // Le paramètre est le JETON de suivi (hotfix_173) : valider est une
      // écriture qui engage le stock, elle exige la possession du lien. Un
      // ancien lien porteur de l'identifiant reste lisible mais se verra
      // refuser la validation — c'est le comportement voulu.
      final result = await db.rpc('validate_order_by_client',
          params: {'p_tracking_token': widget.orderId});
      if (!mounted) return;
      final isOk = result == 'validated' || result == 'already_validated';
      if (isOk) {
        // Reload pour rafraîchir le statut affiché.
        setState(() {
          _future = _load();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.secondary,
            content: Text(
              '✓ Commande validée — la boutique va préparer votre livraison.',
              style: TextStyle(color: Colors.white),
            ),
            duration: Duration(seconds: 4),
          ),
        );
      } else {
        // Réponse inattendue (RPC absente, plan non actif, etc.) → message
        // utile sans dévoiler le détail technique.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Theme.of(context).colorScheme.error,
            content: const Text(
              'Impossible de valider pour le moment. Contactez la boutique.',
              style: TextStyle(color: Colors.white),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Track] validate error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Theme.of(context).colorScheme.error,
          content: const Text(
            'Impossible de valider la commande. Réessayez plus tard.',
            style: TextStyle(color: Colors.white),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: FutureBuilder<_TrackedOrder>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Commande introuvable.\nVérifiez le lien reçu ou '
                  'contactez la boutique.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 14, color: theme.colorScheme.error),
                ),
              ),
            );
          }
          final order = snap.data!;
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(shopName: order.shopName),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (order.clientName != null
                            || order.clientPhone != null
                            || order.clientAddress != null) ...[
                          _ClientCoordinatesCard(order: order),
                          const SizedBox(height: 16),
                        ],
                        _StatusCard(order: order),
                        const SizedBox(height: 16),
                        _ItemsCard(order: order),
                        const SizedBox(height: 16),
                        _TotalCard(order: order),
                        const SizedBox(height: 24),
                        if (order.status == 'scheduled')
                          _ValidateButton(
                            onPressed: _validating
                                ? null
                                : () => _validate(),
                            loading: _validating,
                          ),
                        const SizedBox(height: 12),
                        _CatalogueLink(shopId: order.shopId),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Modèles ──────────────────────────────────────────────────────────────

class _TrackedOrder {
  final String id;
  final String shopId;
  final String status;
  final String shopName;
  final String? clientName;
  final String? clientPhone;
  /// Adresse extraite des notes (ligne « Adresse : ... » écrite par
  /// `place_public_order`). Si pas de ligne adresse → null.
  final String? clientAddress;
  final List<_OrderItem> items;
  final double discountAmount;
  final double taxRate;
  final DateTime? scheduledAt;
  final DateTime createdAt;
  /// Notes RESTANTES (après extraction de la ligne adresse) — affichage
  /// libre du client si jamais il a ajouté un commentaire à la commande.
  final String? notes;

  _TrackedOrder({
    required this.id,
    required this.shopId,
    required this.status,
    required this.shopName,
    required this.clientName,
    required this.clientPhone,
    required this.clientAddress,
    required this.items,
    required this.discountAmount,
    required this.taxRate,
    required this.scheduledAt,
    required this.createdAt,
    required this.notes,
  });

  double get itemsTotal =>
      items.fold(0.0, (sum, it) => sum + (it.unitPrice * it.quantity));

  double get total {
    final base = itemsTotal - discountAmount;
    return base * (1 + taxRate / 100);
  }

  factory _TrackedOrder.fromMap(Map<String, dynamic> m) {
    final rawItems = m['items'];
    final itemsList = (rawItems is List)
        ? rawItems
            .whereType<Map>()
            .map((e) => _OrderItem.fromMap(Map<String, dynamic>.from(e)))
            .toList()
        : <_OrderItem>[];
    final rawNotes = m['notes']?.toString();
    final (address, restNotes) = _splitAddressFromNotes(rawNotes);
    return _TrackedOrder(
      id:           m['id']?.toString() ?? '',
      shopId:       m['shop_id']?.toString() ?? '',
      status:       m['status']?.toString() ?? 'scheduled',
      shopName:     m['shop_name']?.toString() ?? '',
      clientName:   m['client_name']?.toString(),
      clientPhone:  m['client_phone']?.toString(),
      clientAddress: address,
      items:        itemsList,
      discountAmount: (m['discount_amount'] as num?)?.toDouble() ?? 0,
      taxRate:        (m['tax_rate'] as num?)?.toDouble() ?? 0,
      scheduledAt: _parseDate(m['scheduled_at']),
      createdAt:   _parseDate(m['created_at']) ?? DateTime.now(),
      notes:       restNotes,
    );
  }

  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    if (v is DateTime) return v;
    return DateTime.tryParse(v.toString());
  }

  /// Sépare la ligne « Adresse : ... » des autres notes. `place_public_order`
  /// (hotfix_079) injecte cette ligne quand le client a saisi ville/quartier
  /// au moment de la commande. On la remonte en coordonnée structurée pour
  /// l'afficher dans la carte « Vos coordonnées », et on garde le reste
  /// comme « note libre ».
  static (String? address, String? rest) _splitAddressFromNotes(
      String? notes) {
    if (notes == null) return (null, null);
    final lines = notes.split('\n');
    final addrLines = <String>[];
    final restLines = <String>[];
    for (final l in lines) {
      final trimmed = l.trim();
      if (trimmed.startsWith('Adresse :') || trimmed.startsWith('Adresse:')) {
        addrLines.add(trimmed.replaceFirst(RegExp(r'^Adresse\s*:\s*'), ''));
      } else {
        restLines.add(l);
      }
    }
    final addr = addrLines.isEmpty
        ? null
        : addrLines.join(' · ').trim();
    final rest = restLines.join('\n').trim();
    return (
      (addr?.isEmpty ?? true) ? null : addr,
      rest.isEmpty ? null : rest,
    );
  }
}

class _OrderItem {
  final String name;
  final int quantity;
  /// Prix unitaire RÉELLEMENT facturé au client : `custom_price` (prix
  /// modifié dans le panier — ex. rabais accordé) s'il existe, sinon
  /// `unit_price` (prix boutique), puis remise % par ligne appliquée.
  /// Avant, on ne lisait que `unit_price` → le suivi affichait le prix
  /// boutique (ex. 13000) au lieu du prix panier (ex. 12000). Aligné sur
  /// `SaleItem.effectivePrice` / `SaleItem.subtotal`.
  final double unitPrice;
  final String? imageUrl;

  _OrderItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.imageUrl,
  });

  factory _OrderItem.fromMap(Map<String, dynamic> m) {
    final base        = (m['unit_price'] as num?)?.toDouble() ?? 0;
    final custom      = (m['custom_price'] as num?)?.toDouble();
    final discountPct = (m['discount'] as num?)?.toDouble() ?? 0;
    final effective   = (custom ?? base) * (1 - discountPct / 100);
    return _OrderItem(
      name:      (m['product_name'] ?? m['name'] ?? '').toString(),
      quantity:  (m['quantity'] as num?)?.toInt() ?? 1,
      unitPrice: effective,
      imageUrl:  m['image_url']?.toString(),
    );
  }
}

// ─── Header ────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final String shopName;
  const _Header({required this.shopName});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.primary, AppColors.primaryLight],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          const FortressLogo.dark(size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  shopName.isEmpty ? 'Fortress' : shopName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white),
                ),
                Text(
                  'Suivi de votre commande',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.85)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Cards ─────────────────────────────────────────────────────────────────

/// Carte « Vos coordonnées » — affiche EXACTEMENT ce que le client a saisi
/// au moment de passer la commande (nom + téléphone + adresse). Permet
/// au client d'ouvrir le lien et de vérifier d'un coup d'œil que la
/// boutique a bien enregistré ses bonnes coordonnées avant de valider
/// la commande.
class _ClientCoordinatesCard extends StatelessWidget {
  final _TrackedOrder order;
  const _ClientCoordinatesCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fields = <(IconData, String, String)>[];
    if ((order.clientName ?? '').isNotEmpty) {
      fields.add((Icons.person_outline_rounded, 'Nom', order.clientName!));
    }
    if ((order.clientPhone ?? '').isNotEmpty) {
      fields.add((Icons.phone_outlined, 'Téléphone', order.clientPhone!));
    }
    if ((order.clientAddress ?? '').isNotEmpty) {
      fields.add((Icons.location_on_outlined, 'Adresse',
          order.clientAddress!));
    }
    if (fields.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Vos coordonnées',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            'Vérifiez que ces informations correspondent à ce que vous '
            'avez saisi. Si une erreur, contactez la boutique avant de '
            'valider la commande.',
            style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.6)),
          ),
          const SizedBox(height: 12),
          for (int i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(fields[i].$1, size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fields[i].$2,
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.4,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.55)),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        fields[i].$3,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final _TrackedOrder order;
  const _StatusCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color, icon) = _statusBadge(order.status);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Nom déplacé dans `_ClientCoordinatesCard` (rendu juste au-dessus
          // quand au moins une coordonnée est connue) — évite le doublon.
          Row(children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Statut : $label',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: color),
              ),
            ),
          ]),
          if (order.scheduledAt != null) ...[
            const SizedBox(height: 8),
            Text(
              'Livraison prévue : ${_formatDate(order.scheduledAt!)}',
              style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.7)),
            ),
          ],
          if (order.notes != null && order.notes!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              order.notes!,
              style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.6)),
            ),
          ],
        ],
      ),
    );
  }

  (String, Color, IconData) _statusBadge(String s) {
    switch (s) {
      case 'scheduled':
        return ('En attente de votre validation', AppColors.warning,
            Icons.schedule_rounded);
      case 'processing':
        return ('Validée — en préparation', AppColors.secondary,
            Icons.local_shipping_rounded);
      case 'completed':
        return ('Livrée', AppColors.secondary, Icons.check_circle_rounded);
      case 'cancelled':
      case 'refused':
        return ('Annulée', AppColors.error, Icons.cancel_rounded);
      case 'refunded':
        return ('Remboursée', AppColors.error, Icons.replay_rounded);
      default:
        return (s, AppColors.primary, Icons.info_outline_rounded);
    }
  }

  String _formatDate(DateTime d) {
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${pad(d.day)}/${pad(d.month)}/${d.year} à '
        '${pad(d.hour)}:${pad(d.minute)}';
  }
}

class _ItemsCard extends StatelessWidget {
  final _TrackedOrder order;
  const _ItemsCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Vos produits',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.onSurface),
          ),
          const SizedBox(height: 12),
          if (order.items.isEmpty)
            Text(
              'Aucun produit dans cette commande.',
              style: TextStyle(
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurface
                      .withValues(alpha: 0.5)),
            )
          else
            ...order.items.map((it) => _ItemRow(item: it)),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  final _OrderItem item;
  const _ItemRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineTotal = item.unitPrice * item.quantity;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: (item.imageUrl?.startsWith('http') ?? false)
                  ? Image.network(
                      item.imageUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _ImgPlaceholder(),
                    )
                  : _ImgPlaceholder(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.name.isEmpty ? '(produit)' : item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface),
                ),
                const SizedBox(height: 2),
                Text(
                  '${item.quantity} × ${item.unitPrice.toStringAsFixed(0)} XAF',
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${lineTotal.toStringAsFixed(0)} XAF',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: theme.colorScheme.primary),
          ),
        ],
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  final _TrackedOrder order;
  const _TotalCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primarySurface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(Icons.payments_rounded,
            size: 22, color: AppColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Total',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface),
          ),
        ),
        Text(
          '${order.total.toStringAsFixed(0)} XAF',
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: AppColors.primary),
        ),
      ]),
    );
  }
}

class _ValidateButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool loading;
  const _ValidateButton({required this.onPressed, required this.loading});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.check_circle_rounded, size: 20),
        label: Text(
          loading
              ? 'Validation en cours…'
              : 'Valider ma commande',
          style: const TextStyle(
              fontSize: 14, fontWeight: FontWeight.w700),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.secondary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}

class _CatalogueLink extends StatelessWidget {
  final String shopId;
  const _CatalogueLink({required this.shopId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Icon(Icons.shopping_bag_outlined,
                size: 20, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Vous voulez ajouter d\'autres produits ?',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            'Parcourez le catalogue de la boutique. Cliquez sur un produit '
            'pour passer commande directement.',
            style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurface
                    .withValues(alpha: 0.7)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => context.go('/catalogue/$shopId'),
            icon: const Icon(Icons.storefront_rounded, size: 16),
            label: const Text(
              'Voir le catalogue',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: BorderSide(
                  color: AppColors.primary.withValues(alpha: 0.5)),
              padding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ],
      ),
    );
  }
}

class _ImgPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.3),
      child: const Center(
        child: Icon(Icons.inventory_2_outlined,
            size: 24, color: Colors.grey),
      ),
    );
  }
}
