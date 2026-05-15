import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../domain/entities/promo_campaign.dart';
import '../providers/promo_campaign_provider.dart';

// ═════════════════════════════════════════════════════════════════════════════
// CampaignFormSheet — création / édition d'une campagne marketing.
//
// Champs :
//   • type (radio promo / news)
//   • nom
//   • description (optionnel)
//   • sélection multi-produits avec recherche
//   • remise globale en % (optionnel — appliquée à tous les produits)
//   • date limite (optionnel)
//
// Le snapshot des produits est figé à la création (cf. PromoProductSnapshot) :
//   si l'admin modifie un produit après création, la campagne reste cohérente.
// ═════════════════════════════════════════════════════════════════════════════

class CampaignFormSheet extends ConsumerStatefulWidget {
  final String              shopId;
  final PromoCampaign?      existing;
  final PromoCampaignType?  initialType;
  const CampaignFormSheet({
    super.key,
    required this.shopId,
    this.existing,
    this.initialType,
  });

  @override
  ConsumerState<CampaignFormSheet> createState() => _CampaignFormSheetState();
}

class _CampaignFormSheetState extends ConsumerState<CampaignFormSheet> {
  final _nameCtrl     = TextEditingController();
  final _descCtrl     = TextEditingController();
  final _discountCtrl = TextEditingController();
  late PromoCampaignType _type;
  DateTime?  _validUntil;
  final Set<String> _selectedProductIds = {};
  String _searchQuery = '';
  bool   _saving = false;
  String? _nameError, _productsError;

  late List<Product> _allProducts;

  @override
  void initState() {
    super.initState();
    _type = widget.existing?.type
        ?? widget.initialType
        ?? PromoCampaignType.promo;
    _nameCtrl.text = widget.existing?.name ?? '';
    _descCtrl.text = widget.existing?.description ?? '';
    _discountCtrl.text =
        widget.existing?.discountPercent?.toString() ?? '';
    _validUntil = widget.existing?.validUntil;
    _selectedProductIds.addAll(
        widget.existing?.products.map((p) => p.productId) ?? []);
    _allProducts = AppDatabase.getProductsForShop(widget.shopId);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _discountCtrl.dispose();
    super.dispose();
  }

  Iterable<Product> get _filteredProducts {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _allProducts;
    return _allProducts.where((p) =>
        p.name.toLowerCase().contains(q)
        || (p.brand?.toLowerCase().contains(q) ?? false));
  }

  Future<void> _pickValidUntil() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _validUntil ?? now.add(const Duration(days: 7)),
      firstDate:  now,
      lastDate:   now.add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _validUntil = picked);
  }

  PromoProductSnapshot _snapshotFromProduct(Product p) {
    final variant = p.variants.isNotEmpty ? p.variants.first : null;
    final price = variant?.priceSellPos ?? p.priceSellPos;
    final imageUrl = variant?.imageUrl?.isNotEmpty == true
        ? variant!.imageUrl
        : p.mainImageUrl;
    return PromoProductSnapshot(
      productId:     p.id ?? '',
      variantId:     variant?.id,
      name:          p.name,
      imageUrl:      imageUrl,
      originalPrice: price,
    );
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    setState(() {
      _nameError = name.isEmpty ? 'Nom requis' : null;
      _productsError = _selectedProductIds.isEmpty
          ? 'Sélectionnez au moins un produit'
          : null;
    });
    if (_nameError != null || _productsError != null) return;

    setState(() => _saving = true);
    try {
      final selected = _allProducts
          .where((p) => _selectedProductIds.contains(p.id))
          .map(_snapshotFromProduct)
          .toList();
      final discount = int.tryParse(_discountCtrl.text.trim());
      final notifier =
          ref.read(promoCampaignsProvider(widget.shopId).notifier);
      if (widget.existing == null) {
        await notifier.createCampaign(
          type:            _type,
          name:            name,
          products:        selected,
          discountPercent: discount,
          validUntil:      _validUntil,
          description:     _descCtrl.text.trim().isEmpty
              ? null : _descCtrl.text.trim(),
        );
      } else {
        await notifier.updateCampaign(widget.existing!.copyWith(
          type:            _type,
          name:            name,
          products:        selected,
          discountPercent: discount,
          validUntil:      _validUntil,
          description:     _descCtrl.text.trim().isEmpty
              ? null : _descCtrl.text.trim(),
        ));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        AppSnack.error(context, 'Erreur : $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AdaptiveFormFrame(
      title: isEdit ? 'Modifier la campagne' : 'Nouvelle campagne',
      icon: Icons.campaign_outlined,
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Type
              const AppFieldLabel('Type', required: true),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: _TypeRadio(
                  icon: Icons.local_offer_rounded,
                  label: 'Promotion',
                  selected: _type == PromoCampaignType.promo,
                  onTap: () =>
                      setState(() => _type = PromoCampaignType.promo),
                )),
                const SizedBox(width: 8),
                Expanded(child: _TypeRadio(
                  icon: Icons.auto_awesome_rounded,
                  label: 'Nouveautés',
                  selected: _type == PromoCampaignType.news,
                  onTap: () =>
                      setState(() => _type = PromoCampaignType.news),
                )),
              ]),
              const SizedBox(height: 14),
              const AppFieldLabel('Nom', required: true),
              const SizedBox(height: 4),
              AppField(
                controller: _nameCtrl,
                hint: 'Ex : Soldes Black Friday',
                prefixIcon: Icons.title_rounded,
                validator: (_) => _nameError,
              ),
              const SizedBox(height: 14),
              const AppFieldLabel('Description'),
              const SizedBox(height: 4),
              AppField(
                controller: _descCtrl,
                hint: 'Court texte qui apparaîtra sur la vitrine',
                prefixIcon: Icons.notes_rounded,
                maxLines: 2,
              ),
              if (_type == PromoCampaignType.promo) ...[
                const SizedBox(height: 14),
                const AppFieldLabel('Remise globale (%)'),
                const SizedBox(height: 4),
                AppField(
                  controller: _discountCtrl,
                  hint: 'Ex : 20',
                  prefixIcon: Icons.percent_rounded,
                  keyboardType: TextInputType.number,
                ),
              ],
              const SizedBox(height: 14),
              const AppFieldLabel('Valable jusqu\'au'),
              const SizedBox(height: 4),
              InkWell(
                onTap: _pickValidUntil,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: Row(children: [
                    Icon(Icons.event_rounded,
                        size: 16, color: AppColors.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(child: Text(
                      _validUntil == null
                          ? 'Aucune date limite'
                          : '${_validUntil!.day.toString().padLeft(2, '0')}/'
                            '${_validUntil!.month.toString().padLeft(2, '0')}/'
                            '${_validUntil!.year}',
                      style: const TextStyle(fontSize: 13),
                    )),
                    if (_validUntil != null)
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () =>
                            setState(() => _validUntil = null),
                      ),
                  ]),
                ),
              ),
              const SizedBox(height: 14),
              AppFieldLabel(
                  'Produits (${_selectedProductIds.length})',
                  required: true),
              const SizedBox(height: 4),
              if (_productsError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(_productsError!,
                      style: TextStyle(
                          color: AppColors.error, fontSize: 11)),
                ),
              TextField(
                onChanged: (v) => setState(() => _searchQuery = v),
                decoration: InputDecoration(
                  hintText: 'Rechercher un produit…',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  isDense: true,
                  filled: true,
                  fillColor: const Color(0xFFF9FAFB),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: Color(0xFFE5E7EB))),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          const BorderSide(color: Color(0xFFE5E7EB))),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 280,
                child: _allProducts.isEmpty
                    ? Center(
                        child: Text('Aucun produit dans cette boutique.',
                            style: TextStyle(
                                color: AppColors.textHint, fontSize: 12)),
                      )
                    : ListView.builder(
                        itemCount: _filteredProducts.length,
                        itemBuilder: (_, i) {
                          final p = _filteredProducts.elementAt(i);
                          final selected =
                              _selectedProductIds.contains(p.id);
                          return _ProductTile(
                            product: p,
                            selected: selected,
                            onTap: () {
                              setState(() {
                                if (selected) {
                                  _selectedProductIds.remove(p.id);
                                } else {
                                  _selectedProductIds.add(p.id ?? '');
                                }
                              });
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        Padding(
          padding: const EdgeInsets.all(14),
          child: SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.check_rounded, size: 16),
              label: Text(isEdit ? 'Enregistrer' : 'Créer',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _TypeRadio extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final bool         selected;
  final VoidCallback onTap;
  const _TypeRadio({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.08)
              : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: selected
                  ? AppColors.primary
                  : const Color(0xFFE5E7EB),
              width: selected ? 1.5 : 1),
        ),
        child: Column(children: [
          Icon(icon,
              size: 20,
              color: selected ? AppColors.primary : AppColors.textHint),
          const SizedBox(height: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color:
                      selected ? AppColors.primary : AppColors.textPrimary)),
        ]),
      ),
    );
  }
}

class _ProductTile extends StatelessWidget {
  final Product       product;
  final bool          selected;
  final VoidCallback  onTap;
  const _ProductTile({
    required this.product,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final price = product.priceSellPos;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          border: Border(
              bottom: BorderSide(color: AppColors.divider.withValues(alpha: 0.5))),
        ),
        child: Row(children: [
          Checkbox(
            value: selected, onChanged: (_) => onTap(),
            visualDensity: VisualDensity.compact,
            activeColor: AppColors.primary,
          ),
          const SizedBox(width: 4),
          if (product.mainImageUrl != null
              && product.mainImageUrl!.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(product.mainImageUrl!,
                  width: 36, height: 36, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _imgFallback()),
            )
          else
            _imgFallback(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(product.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
                Text(CurrencyFormatter.format(price),
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary)),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _imgFallback() => Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
            color: AppColors.primarySurface.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(6)),
        child: Icon(Icons.image_rounded,
            size: 18,
            color: AppColors.primary.withValues(alpha: 0.4)),
      );
}
