import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/external_launcher.dart';
import '../../../../core/services/short_link_service.dart';
import '../../../../core/services/whatsapp/whatsapp_template_renderer.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/phone_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../crm/domain/entities/client.dart';
import '../../../parametres/data/repositories/whatsapp_template_repository.dart';
import '../../../parametres/domain/entities/whatsapp_template.dart';
import '../../domain/entities/promo_campaign.dart';
import '../providers/promo_campaign_provider.dart';

// ═════════════════════════════════════════════════════════════════════════════
// CampaignSendPage — sélection des clients destinataires + envoi WhatsApp
// séquentiel.
//
// Spec utilisateur : tous les clients cochés par défaut, recherche + déselect
// manuel. L'envoi se fait un par un (web ne permet pas l'envoi groupé via
// wa.me). Bouton "Envoyer au suivant" qui itère sur la liste sélectionnée
// en restant dans le user-gesture.
//
// Le message utilise le template `promo` ou `news` selon le type de campagne.
// Le lien envoyé pointe vers la vitrine publique `/promo/:shopId/:campaignId`.
// ═════════════════════════════════════════════════════════════════════════════

class CampaignSendPage extends ConsumerStatefulWidget {
  final String shopId;
  final String campaignId;
  const CampaignSendPage({
    super.key,
    required this.shopId,
    required this.campaignId,
  });

  @override
  ConsumerState<CampaignSendPage> createState() => _CampaignSendPageState();
}

class _CampaignSendPageState extends ConsumerState<CampaignSendPage> {
  PromoCampaign? _campaign;
  late List<Client> _allClients;
  final Set<String> _selectedIds = {};
  final Set<String> _sentIds     = {};
  String _searchQuery = '';
  String? _previewShortUrl;
  bool _loadingPreview = false;

  @override
  void initState() {
    super.initState();
    _allClients = AppDatabase.getClientsForShop(widget.shopId)
        .where((c) => (c.phone ?? '').trim().isNotEmpty)
        .toList();
    // Par défaut : tous cochés.
    for (final c in _allClients) {
      if (c.id != null) _selectedIds.add(c.id!);
    }
    // Charge la campagne.
    () async {
      final repo = ref.read(promoCampaignRepositoryProvider);
      final c = await repo.getById(widget.campaignId);
      if (mounted) setState(() => _campaign = c);
      // Pré-génère un short-link partagé entre tous les envois pour ne
      // pas créer 1 lien par destinataire (analytics globales OK).
      if (c != null) {
        setState(() => _loadingPreview = true);
        final origin = Uri.base.origin.startsWith('http')
            ? Uri.base.origin
            : 'https://fortress-pos.web.app';
        final longUrl = '$origin/#/promo/${c.shopId}/${c.id}';
        final shortUrl = await ShortLinkService.createShortLink(
              longUrl:   longUrl,
              linkType:  c.type.key,
              expiresIn: const Duration(days: 90),
            )
            ?? longUrl;
        if (mounted) {
          setState(() {
            _previewShortUrl = shortUrl;
            _loadingPreview = false;
          });
        }
      }
    }();
  }

  Iterable<Client> get _filteredClients {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _allClients;
    return _allClients.where((c) =>
        c.name.toLowerCase().contains(q)
        || (c.phone ?? '').contains(q));
  }

  int get _toSendCount => _selectedIds.difference(_sentIds).length;

  Client? get _nextRecipient {
    for (final c in _allClients) {
      if (c.id == null) continue;
      if (!_selectedIds.contains(c.id)) continue;
      if (_sentIds.contains(c.id)) continue;
      return c;
    }
    return null;
  }

  void _sendNext() {
    final campaign = _campaign;
    final shortUrl = _previewShortUrl;
    final next = _nextRecipient;
    if (campaign == null || shortUrl == null || next == null) return;

    final phone = (next.phone ?? '').trim();
    final p = PhoneFormatter.toWame(phone).replaceAll(RegExp(r'[^\d]'), '');
    if (p.isEmpty) {
      // Numéro invalide → on saute en marquant comme envoyé pour ne pas
      // bloquer la queue.
      setState(() => _sentIds.add(next.id!));
      return;
    }

    // Rendu du template (`promo` ou `news` selon le type de campagne).
    final tplRepo = WhatsappTemplateRepository();
    final tplType = campaign.type == PromoCampaignType.promo
        ? WhatsappTemplateType.promo
        : WhatsappTemplateType.news;
    final tpl = tplRepo.getDefault(widget.shopId, tplType);
    final shop = LocalStorageService.getShop(widget.shopId);
    final shopName = shop?.name ?? 'Fortress';
    final productName = campaign.products.isNotEmpty
        ? campaign.products.first.name : '';
    final msg = tpl == null
        ? 'Bonjour ${next.name} 👋\n\n${campaign.name}\n\n'
            '${campaign.type == PromoCampaignType.promo ? "🔥" : "✨"} '
            '$shortUrl\n\n$shopName'
        : WhatsappTemplateRenderer.render(tpl, {
            'client_name':   next.name,
            'shop_name':     shopName,
            'link':          shortUrl,
            'discount':      (campaign.discountPercent ?? 0).toString(),
            'product_name':  productName,
          });

    final waUrl = 'https://wa.me/$p?text=${Uri.encodeComponent(msg)}';
    openExternal(waUrl).then((ok) {
      if (!ok && context.mounted) {
        AppSnack.warning(context,
            'Impossible d\'ouvrir WhatsApp. Autorise les pop-ups.');
        return;
      }
      // Marque envoyé après l'ouverture réussie.
      if (mounted) {
        setState(() => _sentIds.add(next.id!));
      }
      // Incrément analytics côté serveur (fire-and-forget).
      ref.read(promoCampaignRepositoryProvider)
          .incrementSent(widget.campaignId);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selectedIds.length == _allClients.length) {
        _selectedIds.clear();
      } else {
        for (final c in _allClients) {
          if (c.id != null) _selectedIds.add(c.id!);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ready = _campaign != null && _previewShortUrl != null;
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Envoyer la campagne',
      isRootPage: false,
      body: !ready
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : Column(children: [
              _Header(
                campaign: _campaign!,
                shortUrl: _previewShortUrl!,
                loadingPreview: _loadingPreview,
              ),
              Container(
                color: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => setState(() => _searchQuery = v),
                      decoration: InputDecoration(
                        hintText: 'Rechercher un client…',
                        prefixIcon:
                            const Icon(Icons.search_rounded, size: 18),
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFFF9FAFB),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                                color: Color(0xFFE5E7EB))),
                        enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                                color: Color(0xFFE5E7EB))),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                      onPressed: _toggleAll,
                      child: Text(
                          _selectedIds.length == _allClients.length
                              ? 'Tout décocher'
                              : 'Tout cocher',
                          style: const TextStyle(fontSize: 11))),
                ]),
              ),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                child: Row(children: [
                  Text('${_selectedIds.length} sélectionné·s · '
                      '${_sentIds.length} envoyé·s · '
                      '$_toSendCount à envoyer',
                      style: TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: _allClients.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                              'Aucun client avec numéro WhatsApp. '
                              'Ajoutez des clients depuis l\'onglet Clients.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.textHint)),
                        ),
                      )
                    : ListView(
                        children: [
                          for (final c in _filteredClients)
                            _ClientTile(
                              client: c,
                              selected: _selectedIds.contains(c.id),
                              sent: _sentIds.contains(c.id),
                              onTap: () {
                                setState(() {
                                  if (_selectedIds.contains(c.id)) {
                                    _selectedIds.remove(c.id);
                                  } else if (c.id != null) {
                                    _selectedIds.add(c.id!);
                                  }
                                });
                              },
                            ),
                        ],
                      ),
              ),
              SafeArea(child: Padding(
                padding: const EdgeInsets.all(14),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _nextRecipient == null ? null : _sendNext,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: Text(
                        _nextRecipient == null
                            ? 'Tous les envois sont terminés'
                            : 'Envoyer à ${_nextRecipient!.name}',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              )),
            ]),
    );
  }
}

class _Header extends StatelessWidget {
  final PromoCampaign campaign;
  final String        shortUrl;
  final bool          loadingPreview;
  const _Header({
    required this.campaign,
    required this.shortUrl,
    required this.loadingPreview,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      color: AppColors.primary.withValues(alpha: 0.06),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(campaign.name,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${campaign.type.label} · ${campaign.products.length} produits',
              style: TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
          const SizedBox(height: 8),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(children: [
              Icon(Icons.link_rounded,
                  size: 12, color: AppColors.textHint),
              const SizedBox(width: 6),
              Expanded(
                child: loadingPreview
                    ? Text('Génération du lien court…',
                        style: TextStyle(
                            fontSize: 10,
                            fontStyle: FontStyle.italic,
                            color: AppColors.textHint))
                    : SelectableText(shortUrl,
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 10, fontFamily: 'monospace')),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _ClientTile extends StatelessWidget {
  final Client       client;
  final bool         selected;
  final bool         sent;
  final VoidCallback onTap;
  const _ClientTile({
    required this.client,
    required this.selected,
    required this.sent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: sent ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(
                  color: AppColors.divider.withValues(alpha: 0.5))),
        ),
        child: Row(children: [
          Checkbox(
              value: selected,
              onChanged: sent ? null : (_) => onTap(),
              visualDensity: VisualDensity.compact,
              activeColor: AppColors.primary),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(client.name,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: sent
                            ? AppColors.textHint
                            : AppColors.textPrimary)),
                Text(client.phone ?? '',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary)),
              ],
            ),
          ),
          if (sent)
            Icon(Icons.check_circle_rounded,
                size: 16, color: const Color(0xFF25D366)),
        ]),
      ),
    );
  }
}
