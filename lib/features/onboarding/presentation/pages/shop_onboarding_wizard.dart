import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/route_names.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/theme_palette.dart';
import '../../../../core/utils/country_phone_data.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../shop_selector/domain/usecases/create_shop_usecase.dart';
import '../../../shop_selector/presentation/bloc/shop_selector_bloc.dart';

// Mapping pays → monnaie identique à CreateShopPage existante. Dupliqué
// volontairement ici pour ne pas créer une dépendance circulaire entre
// onboarding (UI-only) et shop_selector (logique métier).
const _kCountryCurrency = <String, String>{
  'CM': 'XAF', 'TD': 'XAF', 'CF': 'XAF', 'CG': 'XAF', 'GA': 'XAF', 'GQ': 'XAF',
  'SN': 'XOF', 'CI': 'XOF', 'BF': 'XOF', 'ML': 'XOF', 'NE': 'XOF', 'TG': 'XOF',
  'BJ': 'XOF', 'GW': 'XOF',
  'NG': 'NGN', 'GH': 'GHS', 'MA': 'MAD', 'TN': 'TND',
  'FR': 'EUR', 'BE': 'EUR', 'DE': 'EUR', 'IT': 'EUR', 'ES': 'EUR',
  'US': 'USD', 'CA': 'CAD', 'GB': 'GBP',
};

String _countryFromPhone(String? phone) {
  if (phone == null || phone.isEmpty) return 'CM';
  final sorted = kCountries.toList()
    ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
  for (final c in sorted) {
    if (phone.startsWith(c.dialCode)) return c.isoCode;
  }
  return 'CM';
}

const _kSectors = <_Sector>[
  _Sector('retail',      'Commerce'),
  _Sector('restaurant',  'Restaurant'),
  _Sector('supermarche', 'Supermarché'),
  _Sector('pharmacie',   'Pharmacie'),
  _Sector('ecommerce',   'E-commerce'),
  _Sector('autre',       'Autre'),
];

class _Sector {
  final String key;
  final String label;
  const _Sector(this.key, this.label);
}

/// Wizard d'onboarding boutique (point 5 de l'onboarding spec).
///
/// 3 étapes dans un `PageView`, barre de progression « X / 3 » en haut,
/// boutons « Précédent » / « Suivant » en bas. La 3ᵉ étape soumet via
/// `ShopSelectorBloc.CreateShopRequested` (même DTO que `CreateShopPage`)
/// puis navigue vers le dashboard.
///
/// Étapes
/// ──────
///   1. Nom + type d'activité (6 secteurs canoniques).
///   2. Ville + quartier (optionnel). Les deux sont concaténés dans
///      `address` à la soumission (le schéma `shops` n'a pas de colonne
///      district séparée — cohérent avec CreateShopPage existante).
///   3. Logo (optionnel — selector visuel, upload futur) + palette
///      visuelle (8 cercles `kAllPalettes`, sélection appliquée en
///      temps réel via `themePaletteProvider`).
///
/// L'ancienne `CreateShopPage` standalone reste accessible via
/// `/shop-selector/create` pour les usages avancés (création d'une 2ᵉ
/// boutique depuis le shop-selector).
class ShopOnboardingWizard extends ConsumerStatefulWidget {
  const ShopOnboardingWizard({super.key});

  @override
  ConsumerState<ShopOnboardingWizard> createState() =>
      _ShopOnboardingWizardState();
}

class _ShopOnboardingWizardState
    extends ConsumerState<ShopOnboardingWizard> {
  final _pageCtrl   = PageController();
  final _nameCtrl   = TextEditingController();
  final _cityCtrl   = TextEditingController();
  final _districtCtrl = TextEditingController();

  int     _step    = 0;
  String  _sector  = 'retail';
  String? _palette;
  bool    _submitting = false;

  late final String _country;
  late final String _currency;

  @override
  void initState() {
    super.initState();
    // Pays / monnaie déduits du téléphone du profil (comme CreateShopPage).
    final user = LocalStorageService.getCurrentUser();
    _country  = _countryFromPhone(user?.phone);
    _currency = _kCountryCurrency[_country] ?? 'XAF';
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _nameCtrl.dispose();
    _cityCtrl.dispose();
    _districtCtrl.dispose();
    super.dispose();
  }

  bool get _step1Valid => _nameCtrl.text.trim().length >= 2;
  bool get _step2Valid => _cityCtrl.text.trim().isNotEmpty;
  bool get _step3Valid => true; // palette et logo optionnels

  void _next() {
    final ok = switch (_step) {
      0 => _step1Valid,
      1 => _step2Valid,
      _ => _step3Valid,
    };
    if (!ok) return;
    if (_step >= 2) {
      _submit();
      return;
    }
    setState(() => _step++);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut);
  }

  void _back() {
    if (_step == 0) {
      context.pop();
      return;
    }
    setState(() => _step--);
    _pageCtrl.animateToPage(_step,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut);
  }

  String? _addressFromCityDistrict() {
    final city     = _cityCtrl.text.trim();
    final district = _districtCtrl.text.trim();
    if (city.isEmpty && district.isEmpty) return null;
    if (district.isEmpty) return city;
    if (city.isEmpty)     return district;
    return '$district, $city';
  }

  void _submit() {
    if (_submitting) return;
    setState(() => _submitting = true);
    context.read<ShopSelectorBloc>().add(CreateShopRequested(
          CreateShopParams(
            name:     _nameCtrl.text.trim(),
            sector:   _sector,
            currency: _currency,
            country:  _country,
            phone:    null,
            email:    null,
            address:  _addressFromCityDistrict(),
          ),
        ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: BlocListener<ShopSelectorBloc, ShopSelectorState>(
        listener: (ctx, state) {
          if (state is ShopCreated && _submitting) {
            ref.read(currentShopProvider.notifier).setShop(state.shop);
            ref.read(myShopsProvider.notifier).addShop(state.shop);
            AppSnack.success(ctx,
                '${state.shop.name} créée. Bienvenue chez Fortress !');
            // Fin de création → slides d'intro (une seule fois, ICI). Le
            // redirect ne force plus les slides au login.
            ctx.go(RouteNames.onboardingSlides);
          } else if (state is ShopSelectorError && _submitting) {
            setState(() => _submitting = false);
            AppSnack.error(ctx, state.message);
          }
        },
        child: SafeArea(
          child: Column(
            children: [
              // ── Header : back + titre + progression "X / 3" ────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: AppColors.textSecondary,
                      onPressed: _submitting ? null : _back,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Configurez votre boutique',
                              style: AppTextStyles.subtitleBold),
                          const SizedBox(height: 2),
                          Text('Étape ${_step + 1} / 3',
                              style: AppTextStyles.caption),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // ── Barre de progression ──────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: (_step + 1) / 3,
                    minHeight: 6,
                    backgroundColor:
                        AppColors.primary.withValues(alpha: 0.12),
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                ),
              ),

              // ── Corps : PageView 3 étapes ─────────────────────────────
              Expanded(
                child: PageView(
                  controller: _pageCtrl,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _step = i),
                  children: [
                    _Step1NameSector(
                      nameCtrl: _nameCtrl,
                      sector:   _sector,
                      onSector: (s) => setState(() => _sector = s),
                      onChange: () => setState(() {}),
                    ),
                    _Step2CityDistrict(
                      cityCtrl:     _cityCtrl,
                      districtCtrl: _districtCtrl,
                      onChange:     () => setState(() {}),
                    ),
                    _Step3LogoPalette(
                      selectedPaletteId: _palette
                          ?? ref.watch(themePaletteProvider).id,
                      onSelect: (id) async {
                        setState(() => _palette = id);
                        // Application live : l'utilisateur voit le thème
                        // changer immédiatement (cohérent avec la spec
                        // "ne pas un dropdown").
                        await ref.read(themePaletteProvider.notifier)
                            .setPalette(paletteById(id));
                      },
                    ),
                  ],
                ),
              ),

              // ── Footer : bouton CTA selon l'étape ─────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: AppPrimaryButton(
                  label: _step < 2 ? 'Suivant' : 'Créer ma boutique',
                  icon:  _step < 2
                      ? Icons.arrow_forward_rounded
                      : Icons.check_rounded,
                  isLoading: _submitting,
                  enabled: switch (_step) {
                    0 => _step1Valid,
                    1 => _step2Valid,
                    _ => _step3Valid,
                  },
                  onTap: _next,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 1 — Nom + type d'activité
// ─────────────────────────────────────────────────────────────────────────
class _Step1NameSector extends StatelessWidget {
  final TextEditingController nameCtrl;
  final String                sector;
  final ValueChanged<String>  onSector;
  final VoidCallback          onChange;
  const _Step1NameSector({
    required this.nameCtrl,
    required this.sector,
    required this.onSector,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Identité de la boutique',
              style: AppTextStyles.subtitleBold),
          const SizedBox(height: 6),
          const Text(
            'Le nom apparaîtra sur vos reçus, votre catalogue web et '
            'les messages WhatsApp à vos clients.',
            style: AppTextStyles.bodySecondary,
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 6),
            child: Text('Nom de la boutique', style: AppTextStyles.label),
          ),
          AppField(
            controller: nameCtrl,
            hint:  'Ex. Boutique Etoile',
            onChanged: (_) => onChange(),
          ),
          const SizedBox(height: 20),
          const Text('Type d\'activité', style: AppTextStyles.label),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _kSectors.map((s) {
              final sel = s.key == sector;
              return ChoiceChip(
                label: Text(s.label,
                    style: AppTextStyles.bodySmBold.copyWith(
                        color: sel ? Colors.white : AppColors.textPrimary)),
                selected: sel,
                onSelected: (_) => onSector(s.key),
                selectedColor: AppColors.primary,
                backgroundColor: AppColors.inputFill,
                side: BorderSide(
                    color: sel
                        ? AppColors.primary
                        : AppColors.inputBorder),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 2 — Ville + quartier
// ─────────────────────────────────────────────────────────────────────────
class _Step2CityDistrict extends StatelessWidget {
  final TextEditingController cityCtrl;
  final TextEditingController districtCtrl;
  final VoidCallback          onChange;
  const _Step2CityDistrict({
    required this.cityCtrl,
    required this.districtCtrl,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Où êtes-vous situé ?',
              style: AppTextStyles.subtitleBold),
          const SizedBox(height: 6),
          const Text(
            'L\'adresse aide vos clients à vous trouver et sert pour '
            'la livraison à domicile.',
            style: AppTextStyles.bodySecondary,
          ),
          const SizedBox(height: 20),
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 6),
            child: Text('Ville', style: AppTextStyles.label),
          ),
          AppField(
            controller: cityCtrl,
            hint:  'Ex. Douala',
            onChanged: (_) => onChange(),
          ),
          const SizedBox(height: 14),
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 6),
            child: Text('Quartier', style: AppTextStyles.label),
          ),
          AppField(
            controller: districtCtrl,
            hint:  'Ex. Bonapriso (optionnel)',
            onChanged: (_) => onChange(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Étape 3 — Logo (placeholder) + palette visuelle
// ─────────────────────────────────────────────────────────────────────────
class _Step3LogoPalette extends StatelessWidget {
  final String                selectedPaletteId;
  final ValueChanged<String>  onSelect;
  const _Step3LogoPalette({
    required this.selectedPaletteId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Identité visuelle',
              style: AppTextStyles.subtitleBold),
          const SizedBox(height: 6),
          const Text(
            'Choisissez le thème qui correspond à votre marque. Vous '
            'pourrez l\'ajuster dans les paramètres à tout moment.',
            style: AppTextStyles.bodySecondary,
          ),
          const SizedBox(height: 20),

          // ── Logo (placeholder upload futur) ─────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.inputFill,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.inputBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.image_outlined,
                      color: AppColors.primary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Logo (optionnel)',
                          style: AppTextStyles.bodyBold),
                      SizedBox(height: 2),
                      Text(
                        'À ajouter depuis les paramètres après création.',
                        style: AppTextStyles.bodySmSecondary,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Sélecteur palette (cercles) ──────────────────────────────
          const Text('Couleur principale', style: AppTextStyles.label),
          const SizedBox(height: 12),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: kAllPalettes.map((p) {
              final sel = p.id == selectedPaletteId;
              return GestureDetector(
                onTap: () => onSelect(p.id),
                child: Tooltip(
                  message: p.labelFr,
                  child: Container(
                    width: 48, height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end:   Alignment.bottomRight,
                        colors: p.previewGradient,
                      ),
                      border: Border.all(
                        color: sel ? AppColors.textPrimary
                                   : Colors.transparent,
                        width: sel ? 3 : 0,
                      ),
                      boxShadow: sel ? [
                        BoxShadow(
                          color: p.primary.withValues(alpha: 0.45),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ] : null,
                    ),
                    child: sel
                        ? const Icon(Icons.check_rounded,
                            color: Colors.white, size: 22)
                        : null,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
