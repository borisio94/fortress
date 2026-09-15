import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/whatsapp_service.dart';
import '../../../../core/services/short_link_service.dart';
import '../../../../core/services/whatsapp/whatsapp_template_renderer.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../parametres/domain/entities/whatsapp_template.dart';
import '../../../parametres/presentation/providers/whatsapp_template_provider.dart';
import '../../domain/entities/client.dart';
import '../../../caisse/data/repositories/sale_local_datasource.dart';
import '../../../inventaire/domain/stock_at_location.dart' as stock_loc;
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import 'clients_page.dart';

class ClientDetailPage extends StatefulWidget {
  final String shopId, clientId;
  const ClientDetailPage({super.key, required this.shopId,
      required this.clientId});
  @override
  State<ClientDetailPage> createState() => _ClientDetailPageState();
}

class _ClientDetailPageState extends State<ClientDetailPage> {
  Client? _client;
  /// Créance du client (solde dû sur ses ventes à crédit complétées).
  double _debt = 0;
  /// Lien court du catalogue pré-généré à l'ouverture de la fiche. L'URL
  /// catalogue est fixe (dépend du shop, pas du client) → on la raccourcit
  /// une seule fois ici pour que `_sendCatalogue` puisse l'utiliser
  /// SYNCHRONIQUEMENT au clic (wa.me sur web exige un user-gesture sans
  /// await préalable). Fallback URL longue si pas encore prêt.
  String? _catalogueShortUrl;

  @override
  void initState() {
    super.initState();
    _load();
    _prepareCatalogueShortLink();
    AppDatabase.addListener(_onDbChanged);
  }

  Future<void> _prepareCatalogueShortLink() async {
    final origin = Uri.base.origin.startsWith('http')
        ? Uri.base.origin
        : 'https://fortress-pos.web.app';
    // Le lien catalogue est construit comme « Envoyer le catalogue » de
    // l'inventaire (qui fonctionne) : on embarque les `ids` des produits
    // actifs EN STOCK + un snapshot de stock calculé sur les STOCK_LEVELS
    // (tous les emplacements de l'owner), pas sur `variant.stockAvailable`.
    //
    // C'EST LE POINT CLÉ : dans le modèle multi-emplacement, le stock réel
    // vit dans `stock_levels` ; `p.totalStock` et `products.stock_qty` valent
    // 0. Un lien générique (sans snapshot) faisait donc retirer tous les
    // produits par le filtre « stock <= 0 » côté page catalogue → « aucun
    // produit ». Le snapshot stock_levels corrige ça. Les `ids` routent vers
    // la RPC `get_delivery_products` qui bypasse `is_visible_web`.
    //
    // `resolveLocationIds(null, …)` = vue Globale (boutique + partenaires de
    // l'owner) ; si le shop n'a pas de stock_levels, ça retombe proprement
    // sur `p.totalStock`. Snapshot figé à l'ouverture de la fiche.
    final locIds = stock_loc.resolveLocationIds(null, widget.shopId);
    final products = AppDatabase.getProductsForShop(widget.shopId)
        .where((p) => p.id != null
            && p.isActive
            && stock_loc.stockAtLocations(p, locIds) > 0)
        .toList();
    final ids = products.map((p) => p.id!).toList();

    // Snapshot — mêmes clés que CataloguePage._load / _buildStockSnapshot :
    //   produit ≤1 vraie variante → `productId` ; sinon `productId|<idx>`.
    final snapshot = <String, int>{};
    for (final p in products) {
      final realVariants =
          p.variants.where((v) => v.name.trim().isNotEmpty).toList();
      if (realVariants.length <= 1) {
        snapshot[p.id!] = stock_loc.stockAtLocations(p, locIds);
      } else {
        for (var i = 0; i < realVariants.length; i++) {
          snapshot['${p.id!}|$i'] =
              stock_loc.stockForVariantAtLocations(realVariants[i], locIds);
        }
      }
    }

    // Emplacement boutique → orders.delivery_location_id côté commande client.
    final shareLocId = AppDatabase.getShopLocation(widget.shopId)?.id;

    final qp = <String>[];
    if (ids.isNotEmpty) qp.add('ids=${ids.join(",")}');
    if (snapshot.isNotEmpty) {
      qp.add('stock=${snapshot.entries.map((e) => '${e.key}:${e.value}').join(",")}');
    }
    if (shareLocId != null && shareLocId.isNotEmpty) {
      qp.add('loc=$shareLocId');
    }
    final base = '$origin/catalogue/${widget.shopId}';
    final longUrl = qp.isEmpty ? base : '$base?${qp.join("&")}';

    // Hedge idempotent : publie aussi les produits (utile si le lien retombe
    // un jour sur le chemin is_visible_web). Fire-and-forget.
    if (products.isNotEmpty) {
      AppDatabase.markProductsVisibleWeb(products).catchError((e) {
        debugPrint('[Catalogue CRM] markProductsVisibleWeb: $e');
      });
    }

    try {
      final short = await ShortLinkService.createShortLink(
        longUrl:   longUrl,
        linkType:  'catalogue',
        expiresIn: const Duration(days: 365),
      );
      // Sur échec du raccourcisseur, on garde l'URL longue (qui contient déjà
      // ids+stock) plutôt que le fallback générique de `_sendCatalogue`.
      if (mounted) {
        setState(() => _catalogueShortUrl = short ?? longUrl);
      }
    } catch (_) {
      if (mounted) setState(() => _catalogueShortUrl = longUrl);
    }
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    if (table == 'clients' || table == 'orders') _load();
  }

  void _load() {
    final clients = AppDatabase.getClientsForShop(widget.shopId);
    setState(() {
      _client = clients.where((c) => c.id == widget.clientId).firstOrNull;
      _debt = SaleLocalDatasource().clientDebt(widget.shopId, widget.clientId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    if (client == null) {
      return AppScaffold(shopId: widget.shopId, title: 'Client',
          isRootPage: false,
          body: const Center(child: Text('Client introuvable')));
    }

    final color    = _avatarColor(client.id);
    final initial  = client.name.isNotEmpty ? client.name[0].toUpperCase() : '?';
    final daysAgo  = client.lastVisitAt != null
        ? DateTime.now().difference(client.lastVisitAt!).inDays : null;

    return AppScaffold(
      shopId: widget.shopId,
      title: client.name,
      isRootPage: false,
      actions: [
        if ((client.phone ?? '').trim().isNotEmpty)
          IconButton(
            icon: const Icon(Icons.send_rounded, size: 20),
            // Couleur officielle WhatsApp — sémantique forte pour le bouton.
            color: const Color(0xFF25D366),
            tooltip: 'Envoyer un message WhatsApp',
            onPressed: () => _composeWhatsappMessage(context, client),
          ),
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 20),
          color: AppColors.primary,
          onPressed: () => _showEdit(context, client),
        ),
      ],
      // Défilable même contenu court : geste « tirer pour actualiser ».
      body: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero, children: [
        // ── Hero ────────────────────────────────────────────────────
        _HeroHeader(client: client, color: color, initial: initial,
            daysAgo: daysAgo),

        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            // ── KPI ─────────────────────────────────────────────────
            Row(children: [
              Expanded(child: _KpiCard(
                icon: Icons.payments_rounded, color: AppColors.primary,
                label: 'Total dépensé',
                value: CurrencyFormatter.format(client.totalSpent),
              )),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                icon: Icons.receipt_rounded, color: AppColors.secondary,
                label: 'Commandes',
                value: '${client.totalOrders}',
              )),
              const SizedBox(width: 10),
              Expanded(child: _KpiCard(
                icon: Icons.trending_up_rounded,
                color: const Color(0xFFF59E0B),
                label: 'Moy./cmd',
                value: client.totalOrders > 0
                    ? CurrencyFormatter.format(
                        client.totalSpent / client.totalOrders)
                    : '—',
              )),
            ]),
            // Créance (vente à crédit non soldée) — bandeau warning.
            if (_debt > 0) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppColors.warning.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  const Icon(Icons.account_balance_wallet_rounded,
                      size: 16, color: AppColors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Créance en cours',
                        style: AppTextStyles.bodySm.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.8))),
                  ),
                  Text(CurrencyFormatter.format(_debt),
                      style: AppTextStyles.bodyBold
                          .copyWith(color: AppColors.warning)),
                ]),
              ),
            ],
            const SizedBox(height: 16),

            // ── Coordonnées ──────────────────────────────────────────
            _Section(title: 'Coordonnées', icon: Icons.contact_page_outlined,
                child: _CoordinatesContent(client: client)),
            const SizedBox(height: 16),

            // ── Notes ────────────────────────────────────────────────
            if (client.notes != null && client.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _Section(title: 'Notes internes', icon: Icons.notes_rounded,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(client.notes!,
                        style: AppTextStyles.body.copyWith(
                            color: AppColors.onSurface)),
                  )),
            ],
            const SizedBox(height: 16),

            // ── Actions ──────────────────────────────────────────────
            _Section(title: 'Actions', icon: Icons.bolt_rounded,
                child: Column(children: [
              _ActionTile(icon: Icons.receipt_long_rounded,
                  color: AppColors.primary,
                  label: 'Nouvelle commande',
                  onTap: () => context.push(
                      '/shop/${widget.shopId}/caisse'
                      '?clientId=${Uri.encodeComponent(widget.clientId)}')),
              const _Div(),
              _ActionTile(icon: Icons.collections_bookmark_outlined,
                  color: AppColors.secondary,
                  label: context.l10n.catalogueSendBtn,
                  onTap: () => _sendCatalogue(context, client)),
              const _Div(),
              _ActionTile(icon: Icons.edit_outlined,
                  color: AppColors.textSecondary,
                  label: 'Modifier les informations',
                  onTap: () => _showEdit(context, client)),
            ])),
            const SizedBox(height: 24),
          ]),
        ),
      ]),
    );
  }

  /// Ouvre un dialog de saisie de message libre, puis envoie via
  /// `WhatsappService.sendMessage` (provider actif = WameProvider →
  /// `wa.me/<phone>?text=…`). Le numéro client est normalisé via
  /// `PhoneFormatter.toWame` pour gérer les formats `+237 6XX…` /
  /// `06XX…` / `6XX…` indifféremment.
  /// Envoie le lien public du catalogue par WhatsApp.
  /// **Synchrone** jusqu'à `launchUrl` — sur web, un await préalable
  /// rompt le user gesture et le navigateur bloque la fenêtre wa.me.
  void _sendCatalogue(BuildContext context, Client client) {
    final phone = (client.phone ?? '').trim();
    if (phone.isEmpty) {
      AppSnack.warning(context, 'Numéro WhatsApp manquant.');
      return;
    }
    final p = PhoneFormatter.toWame(phone).replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) {
      AppSnack.error(context, 'Numéro WhatsApp invalide.');
      return;
    }
    final origin = Uri.base.origin.startsWith('http')
        ? Uri.base.origin
        : 'https://fortress-pos.web.app';
    // Lien court pré-généré (initState) si dispo, sinon fallback URL longue
    // (jamais bloquant — wa.me doit s'ouvrir dans le tick du clic sur web).
    final link = _catalogueShortUrl
        ?? '$origin/catalogue/${widget.shopId}';
    final shop = LocalStorageService.getShop(widget.shopId);
    final shopName = shop?.name ?? 'Fortress';
    final clientName = client.name;

    final container = ProviderScope.containerOf(context, listen: false);
    final tplRepo = container.read(whatsappTemplateRepositoryProvider);
    final tpl =
        tplRepo.getDefault(widget.shopId, WhatsappTemplateType.catalogue);

    final msg = tpl == null
        ? 'Bonjour $clientName 👋\n\n'
            'Découvrez notre catalogue.\n\n🛍️ $link\n\n'
            'À très bientôt !\n\n$shopName'
        : WhatsappTemplateRenderer.render(tpl, {
            'client_name': clientName,
            'shop_name':   shopName,
            'link':        link,
          });

    final waUrl = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';
    openExternal(waUrl).then((ok) {
      if (!ok && context.mounted) {
        AppSnack.error(context,
            'Impossible d\'ouvrir WhatsApp. Autorisez les pop-ups dans le navigateur.');
      }
    });
  }

  Future<void> _composeWhatsappMessage(
      BuildContext context, Client client) async {
    final phone = (client.phone ?? '').trim();
    if (phone.isEmpty) return;
    // Refonte UX : dialog → bottom sheet verrouillé (showFormSheet).
    final message = await showFormSheet<String>(
      context: context,
      builder: (_) => _WhatsappComposeDialog(clientName: client.name),
    );
    if (message == null || message.trim().isEmpty) return;
    if (!context.mounted) return;
    final svc = ProviderScope.containerOf(context, listen: false)
        .read(whatsappServiceProvider);
    final ok = await svc.sendMessage(
        PhoneFormatter.toWame(phone), message.trim());
    if (!ok && context.mounted) {
      AppSnack.error(context,
          'Impossible d\'ouvrir WhatsApp.');
    }
  }

  void _showEdit(BuildContext context, Client client) {
    showAdaptiveFormSheet(
      context: context,
      builder: (ctx) => ClientFormSheet(
        shopId: widget.shopId,
        client: client,
        onSaved: () {
          Navigator.of(ctx).pop();
          _load();
          AppSnack.success(context, 'Client modifié !');
        },
        onDeleted: () {
          Navigator.of(ctx).pop();
          context.pop();
          AppSnack.success(context, 'Client supprimé');
        },
      ),
    );
  }

  Color _avatarColor(String id) {
    const colors = [
      Color(0xFF6C3FC7), Color(0xFF3B82F6), Color(0xFF10B981),
      Color(0xFFEF4444), Color(0xFFF59E0B), Color(0xFF8B5CF6),
    ];
    return colors[id.hashCode.abs() % colors.length];
  }

}

// ─── Section coordonnées (téléphone, email, ville, quartier) ────────────────
class _CoordinatesContent extends StatelessWidget {
  final Client client;
  const _CoordinatesContent({required this.client});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[];
    void addTile(IconData icon, String label, String? value) {
      if (value == null || value.isEmpty) return;
      if (tiles.isNotEmpty) tiles.add(const _Div());
      tiles.add(_InfoTile(icon: icon, label: label, value: value));
    }

    addTile(Icons.phone_outlined,         'Téléphone', client.phone);
    addTile(Icons.email_outlined,         'Email',     client.email);
    addTile(Icons.location_city_outlined, 'Ville',     client.city);
    addTile(Icons.place_outlined,         'Quartier',  client.district);

    if (tiles.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: Text('Aucune coordonnée renseignée',
            style: AppTextStyles.bodySm.copyWith(
                color: AppColors.textHint))),
      );
    }
    return Column(children: tiles);
  }
}

// ─── Hero ─────────────────────────────────────────────────────────────────────
class _HeroHeader extends StatelessWidget {
  final Client client; final Color color;
  final String initial; final int? daysAgo;
  const _HeroHeader({required this.client, required this.color,
      required this.initial, required this.daysAgo});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.surface,
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
    child: Column(children: [
      Stack(alignment: Alignment.center, children: [
        Container(width: 80, height: 80,
            decoration: BoxDecoration(color: color.withValues(alpha:0.12),
                shape: BoxShape.circle)),
        Container(width: 70, height: 70,
            decoration: BoxDecoration(color: color.withValues(alpha:0.2),
                shape: BoxShape.circle),
            child: Center(child: Text(initial,
                style: AppTextStyles.display.copyWith(color: color)))),
        if (client.tag == ClientTag.vip)
          Positioned(right: 0, bottom: 0,
              child: Container(width: 24, height: 24,
                  decoration: const BoxDecoration(
                      color: Color(0xFFF59E0B), shape: BoxShape.circle),
                  child: const Icon(Icons.workspace_premium_rounded,
                      size: 14, color: Colors.white))),
      ]),
      const SizedBox(height: 12),
      Text(client.name, style: AppTextStyles.title.copyWith(
          color: Theme.of(context).colorScheme.onSurface)),
      if (client.phone != null) ...[
        const SizedBox(height: 4),
        Text(client.phone!, style: AppTextStyles.bodySecondary),
      ],
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (client.tag != ClientTag.none) ...[
          _TagChip(client.tag),
          const SizedBox(width: 8),
        ],
        if (daysAgo != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: daysAgo! <= 7
                  ? AppColors.secondary.withValues(alpha:0.1)
                  : AppColors.inputFill,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.access_time_rounded, size: 11,
                  color: daysAgo! <= 7 ? AppColors.secondary
                      : AppColors.textHint),
              const SizedBox(width: 4),
              Text(daysAgo == 0 ? "Actif aujourd'hui"
                  : daysAgo == 1 ? 'Actif hier'
                  : 'Inactif $daysAgo j',
                  style: AppTextStyles.captionBold.copyWith(
                      color: daysAgo! <= 7 ? AppColors.secondary
                          : AppColors.textHint)),
            ]),
          ),
      ]),
    ]),
  );
}

// ─── Widgets atomiques ────────────────────────────────────────────────────────
class _KpiCard extends StatelessWidget {
  final IconData icon; final Color color;
  final String label, value;
  const _KpiCard({required this.icon, required this.color,
      required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: color.withValues(alpha:0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha:0.15))),
    child: Column(children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(height: 6),
      Text(value, style: AppTextStyles.bodyBold.copyWith(color: color),
          textAlign: TextAlign.center),
      const SizedBox(height: 2),
      Text(label, textAlign: TextAlign.center,
          style: AppTextStyles.micro.copyWith(
              color: AppColors.textHint)),
    ]),
  );
}

class _Section extends StatelessWidget {
  final String title; final IconData icon;
  final Widget child; final Widget? trailing;
  const _Section({required this.title, required this.icon,
      required this.child, this.trailing});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    Row(children: [
      Icon(icon, size: 14, color: AppColors.primary),
      const SizedBox(width: 6),
      Text(title, style: AppTextStyles.bodySmBold.copyWith(
          color: AppColors.onSurface)),
      if (trailing != null) ...[const Spacer(), trailing!],
    ]),
    const SizedBox(height: 8),
    Container(decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
        child: child),
  ]);
}

class _InfoTile extends StatelessWidget {
  final IconData icon; final String label, value;
  const _InfoTile({required this.icon, required this.label,
      required this.value});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    child: Row(children: [
      Icon(icon, size: 15, color: AppColors.textHint),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Text(label, style: AppTextStyles.micro.copyWith(
            color: AppColors.textHint)),
        const SizedBox(height: 2),
        Text(value, style: AppTextStyles.bodyBold.copyWith(
            color: Theme.of(context).colorScheme.onSurface)),
      ])),
    ]),
  );
}

class _ActionTile extends StatelessWidget {
  final IconData icon; final Color color;
  final String label; final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.color,
      required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap, borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Container(width: 34, height: 34,
            decoration: BoxDecoration(color: color.withValues(alpha:0.1),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 12),
        Expanded(child: Text(label, style: AppTextStyles.bodyBold.copyWith(
            color: Theme.of(context).colorScheme.onSurface))),
        Icon(Icons.chevron_right_rounded,
            size: 16, color: AppColors.textHint),
      ]),
    ),
  );
}

class _TagChip extends StatelessWidget {
  final ClientTag tag;
  const _TagChip(this.tag);
  @override
  Widget build(BuildContext context) {
    final color = tag == ClientTag.vip ? const Color(0xFFF59E0B)
        : tag == ClientTag.new_ ? AppColors.secondary : AppColors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha:0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha:0.3))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (tag == ClientTag.vip)
          Padding(padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.workspace_premium_rounded,
                  size: 11, color: color)),
        Text(tag.label, style: AppTextStyles.captionBold.copyWith(
            color: color)),
      ]),
    );
  }
}

class _Div extends StatelessWidget {
  const _Div();
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, color: AppColors.inputFill, indent: 16);
}

// ─── Dialog : composer un message WhatsApp pour le client ─────────────────
class _WhatsappComposeDialog extends StatefulWidget {
  final String clientName;
  const _WhatsappComposeDialog({required this.clientName});

  @override
  State<_WhatsappComposeDialog> createState() =>
      _WhatsappComposeDialogState();
}

class _WhatsappComposeDialogState extends State<_WhatsappComposeDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasText = _ctrl.text.trim().isNotEmpty;
    return AdaptiveFormFrame(
      title: 'Message WhatsApp à ${widget.clientName}',
      icon: Icons.send_rounded,
      iconColor: const Color(0xFF25D366),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                maxLines: 6,
                minLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Tape ton message ici…',
                  hintStyle: AppTextStyles.bodySm.copyWith(
                      color: AppColors.textHint),
                  isDense: true,
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context).semantic.borderSubtle)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                          color: Theme.of(context).semantic.borderSubtle)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(
                          color: Color(0xFF25D366), width: 1.5)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                    ),
                    child: const Text('Annuler'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: hasText
                        ? () => Navigator.of(context).pop(_ctrl.text)
                        : null,
                    icon: const Icon(Icons.send_rounded, size: 14),
                    label: const Text('Envoyer'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: AppColors.divider,
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
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

