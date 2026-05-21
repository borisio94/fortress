import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/logo_color_extractor.dart';
import '../../../../core/services/logo_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../shared/widgets/app_snack.dart';

/// Section « Logo de la boutique » — preview circulaire + import +
/// suppression. Visible sur l'onglet Boutique de la page paramètres
/// (`_OverviewTab` dans `shop_settings_page.dart`).
///
/// Flow :
///   1. Tap « Importer » → `image_picker` ouvre la galerie / caméra.
///   2. `LogoStorageService.uploadLogo` compresse à 512px / 200 KB,
///      uploade vers Supabase Storage `shop_logos`, met à jour le
///      cache local.
///   3. `LogoColorExtractor.extractAndCache` extrait les 2 couleurs
///      dominantes pour personnaliser la facture PDF.
///   4. `AppDatabase.updateShopLogoUrl` met à jour `shops.logo_url`
///      (push Supabase + cache Hive) → propagation Realtime aux
///      autres devices du même owner.
class ShopLogoSection extends ConsumerStatefulWidget {
  final String shopId;
  const ShopLogoSection({super.key, required this.shopId});

  @override
  ConsumerState<ShopLogoSection> createState() =>
      _ShopLogoSectionState();
}

class _ShopLogoSectionState extends ConsumerState<ShopLogoSection> {
  bool _busy = false;
  // Cache mémoire des bytes courants — évite de re-fetch à chaque
  // build (le widget est dans une ListView, sujette à scroll rebuilds).
  Uint8List? _localBytes;

  @override
  void initState() {
    super.initState();
    _localBytes = LogoStorageService.cachedBytes(widget.shopId);
    // Si pas de bytes en cache mais URL connue, on tente un fetch en
    // arrière-plan. Aucune attente : si ça échoue, le placeholder
    // reste affiché.
    if (_localBytes == null) {
      _hydrateFromUrl();
    }
  }

  Future<void> _hydrateFromUrl() async {
    final shop = ref.read(currentShopProvider);
    final url = shop?.logoUrl;
    if (url == null || url.isEmpty) return;
    final bytes = await LogoStorageService.fetchBytes(
        shopId: widget.shopId, url: url);
    if (!mounted || bytes == null) return;
    setState(() => _localBytes = bytes);
    // Profite de l'hydratation pour extraire les couleurs si elles
    // étaient au fallback (cas : changement de device).
    final cached = LogoColorExtractor.cached(widget.shopId);
    final isFallback =
        cached.primary  == LogoColorExtractor.defaultPrimary &&
        cached.secondary == LogoColorExtractor.defaultSecondary;
    if (isFallback) {
      await LogoColorExtractor.extractAndCache(
          shopId: widget.shopId, bytes: bytes);
    }
  }

  Future<void> _pickAndUpload() async {
    if (_busy) return;
    final picker = ImagePicker();
    final XFile? file;
    try {
      file = await picker.pickImage(source: ImageSource.gallery);
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Sélection annulée : $e');
      return;
    }
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final raw = await file.readAsBytes();
      final url = await LogoStorageService.uploadLogo(
          shopId: widget.shopId, rawBytes: raw);
      if (url == null) {
        if (mounted) {
          AppSnack.error(context,
              'Logo trop volumineux ou format non supporté.');
        }
        return;
      }
      // Récupère les bytes effectivement uploadés (post-compression).
      final cachedBytes = LogoStorageService.cachedBytes(widget.shopId);
      await LogoColorExtractor.extractAndCache(
          shopId: widget.shopId, bytes: cachedBytes);
      await AppDatabase.updateShopLogoUrl(widget.shopId, url);
      ref.invalidate(currentShopProvider);
      if (mounted) {
        setState(() => _localBytes = cachedBytes);
        AppSnack.success(context, 'Logo mis à jour');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec upload : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Supprimer le logo ?'),
        content: const Text(
            'La facture utilisera les couleurs par défaut.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('Annuler')),
          TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              style: TextButton.styleFrom(
                  foregroundColor: Theme.of(c).colorScheme.error),
              child: const Text('Supprimer')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _busy = true);
    try {
      await LogoStorageService.deleteLogo(widget.shopId);
      await AppDatabase.updateShopLogoUrl(widget.shopId, null);
      ref.invalidate(currentShopProvider);
      if (mounted) {
        setState(() => _localBytes = null);
        AppSnack.success(context, 'Logo supprimé');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Échec suppression : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasLogo = _localBytes != null;
    final sem = theme.semantic;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Avatar circulaire 80×80
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: hasLogo
                  ? Colors.white
                  : AppColors.primary.withValues(alpha: 0.08),
              border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: hasLogo
                ? Image.memory(_localBytes!, fit: BoxFit.contain)
                : Center(
                    child: Icon(Icons.storefront_rounded,
                        size: 36,
                        color: AppColors.primary
                            .withValues(alpha: 0.5))),
          ),
          const SizedBox(width: 14),
          // Texte + actions
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Logo de la boutique',
                    style: AppTextStyles.body
                        .copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  hasLogo
                      ? 'Apparaîtra sur vos factures PDF.'
                      : 'Ajoutez un logo pour personnaliser vos factures.',
                  style: AppTextStyles.caption.copyWith(
                      color: theme.colorScheme.onSurface
                          .withValues(alpha: 0.65)),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  if (_busy)
                    const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else ...[
                    OutlinedButton.icon(
                      onPressed: _pickAndUpload,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(
                            color: AppColors.primary
                                .withValues(alpha: 0.4)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        textStyle: AppTextStyles.captionBold,
                      ),
                      icon: const Icon(Icons.upload_rounded, size: 16),
                      label: Text(hasLogo ? 'Changer' : 'Importer'),
                    ),
                    if (hasLogo) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _delete,
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          textStyle: AppTextStyles.captionBold,
                        ),
                        icon: const Icon(Icons.delete_outline_rounded,
                            size: 16),
                        label: const Text('Supprimer'),
                      ),
                    ],
                  ],
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
