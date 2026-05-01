import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../bloc/shop_selector_bloc.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/country_phone_data.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../domain/usecases/create_shop_usecase.dart';
import '../../../../shared/providers/current_shop_provider.dart';

// ── Mapping pays → monnaie ────────────────────────────────────────────────────
const _countryCurrency = {
  'CM': 'XAF', 'TD': 'XAF', 'CF': 'XAF', 'CG': 'XAF', 'GA': 'XAF', 'GQ': 'XAF',
  'SN': 'XOF', 'CI': 'XOF', 'BF': 'XOF', 'ML': 'XOF', 'NE': 'XOF', 'TG': 'XOF',
  'BJ': 'XOF', 'GW': 'XOF',
  'NG': 'NGN', 'GH': 'GHS', 'MA': 'MAD', 'TN': 'TND',
  'FR': 'EUR', 'BE': 'EUR', 'DE': 'EUR', 'IT': 'EUR', 'ES': 'EUR',
  'US': 'USD', 'CA': 'CAD', 'GB': 'GBP',
};

/// Déduit le pays depuis le numéro de téléphone (dialCode → isoCode)
String _countryFromPhone(String? phone) {
  if (phone == null || phone.isEmpty) return 'CM';
  final sorted = kCountries.toList()
    ..sort((a, b) => b.dialCode.length.compareTo(a.dialCode.length));
  for (final c in sorted) {
    if (phone.startsWith(c.dialCode)) return c.isoCode;
  }
  return 'CM';
}

class CreateShopPage extends ConsumerStatefulWidget {
  const CreateShopPage({super.key});
  @override
  ConsumerState<CreateShopPage> createState() => _CreateShopPageState();
}

class _CreateShopPageState extends ConsumerState<CreateShopPage> {
  final _nameCtrl    = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _emailCtrl   = TextEditingController();

  String _sector   = 'retail';
  late String _country;
  late String _currency;

  // ── Erreurs temps réel ────────────────────────────────────────────────────
  String? _nameError;
  String? _emailError;
  String? _phoneError;
  String _phoneFull  = '';
  bool   _phoneValid = false;

  bool get _valid =>
      _nameError == null &&
          _emailError == null &&
          _nameCtrl.text.trim().length >= 2;

  @override
  void initState() {
    super.initState();
    // Déduire pays + monnaie depuis le profil de l'utilisateur
    final user  = LocalStorageService.getCurrentUser();
    _country  = _countryFromPhone(user?.phone);
    _currency = _countryCurrency[_country] ?? 'XAF';

    _nameCtrl.addListener(() => setState(() =>
    _nameError = _validateName(_nameCtrl.text)));
    _emailCtrl.addListener(() => setState(() =>
    _emailError = _validateEmail(_emailCtrl.text)));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  static String? _validateName(String v) {
    final s = v.trim();
    if (s.isEmpty) return null; // pas d'erreur tant qu'on n'a pas touché
    if (s.length < 2) return 'Minimum 2 caractères';
    if (s.length > 60) return 'Maximum 60 caractères';
    return null;
  }

  static String? _validateEmail(String v) {
    final s = v.trim();
    if (s.isEmpty) return null; // optionnel
    if (!RegExp(r'^[\w._%+\-]+@[\w.\-]+\.[a-zA-Z]{2,}$').hasMatch(s))
      return 'Email invalide';
    return null;
  }

  void _submit() {
    setState(() {
      _nameError  = _nameCtrl.text.trim().isEmpty
          ? 'Nom requis' : _validateName(_nameCtrl.text);
      _emailError = _validateEmail(_emailCtrl.text);
    });
    if (_nameError != null || _emailError != null) return;

    context.read<ShopSelectorBloc>().add(CreateShopRequested(
      CreateShopParams(
        name:     _nameCtrl.text.trim(),
        sector:   _sector,
        currency: _currency,
        country:  _country,
        phone:    _phoneCtrl.text.trim().isNotEmpty
            ? _phoneCtrl.text.trim() : null,
        email:    _emailCtrl.text.trim().isNotEmpty
            ? _emailCtrl.text.trim() : null,
        address:  _addressCtrl.text.trim().isNotEmpty
            ? _addressCtrl.text.trim() : null,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: BlocConsumer<ShopSelectorBloc, ShopSelectorState>(
        listener: (context, state) {
          if (state is ShopCreated) {
            ref.read(currentShopProvider.notifier).setShop(state.shop);
            ref.read(myShopsProvider.notifier).addShop(state.shop);
            ref.read(myShopsProvider.notifier).refresh();
            ActivityLogService.log(
              action:      'shop_created',
              targetType:  'shop',
              targetId:    state.shop.id,
              targetLabel: state.shop.name,
              shopId:      state.shop.id,
              details:     {
                'sector':   state.shop.sector,
                'currency': state.shop.currency,
                'country':  state.shop.country,
              },
            );
            AppSnack.success(context, '${state.shop.name} créée avec succès !');
            context.go('/shop/${state.shop.id}/dashboard');
          }
          if (state is ShopSelectorError) {
            AppSnack.error(context, state.message);
          }
        },
        builder: (context, state) {
          final l = context.l10n;
          final isLoading = state is ShopSelectorLoading;
          return Stack(children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: LayoutBuilder(builder: (context, box) {
                  final isDesktop = box.maxWidth >= 600;
                  return Center(
                    child: Container(
                      width: isDesktop ? 480 : double.infinity,
                      decoration: isDesktop ? BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20)) : null,
                      color: isDesktop ? null : Colors.white,
                      padding: EdgeInsets.symmetric(
                          horizontal: isDesktop ? 36 : 20,
                          vertical: isDesktop ? 36 : 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [

                          // ── Header ───────────────────────────────
                          Row(children: [
                            const FortressLogo.light(size: 26),
                            const Spacer(),
                            InkWell(
                              onTap: () => context.pop(),
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3F4F6),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(Icons.close,
                                    size: 16, color: Color(0xFF6B7280)),
                              ),
                            ),
                          ]),
                          const SizedBox(height: 24),

                          // ── Icône + titre ────────────────────────
                          Center(
                            child: Container(
                              width: 56, height: 56,
                              decoration: BoxDecoration(
                                color: AppColors.primarySurface,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.storefront_rounded,
                                  size: 26, color: AppColors.primary),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Center(child: Text(l.shopNew,
                              style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F172A)))),
                          const SizedBox(height: 4),
                          const Center(child: Text(
                              'Configurez votre espace de vente',
                              style: TextStyle(
                                  fontSize: 12, color: Color(0xFF6B7280)))),
                          const SizedBox(height: 28),

                          // ── Nom boutique ─────────────────────────
                          AppLabeledField(
                            label: 'Nom de la boutique', required: true,
                            child: AppField(
                              controller: _nameCtrl,
                              hint: 'Ex: Mon Magasin Centre-ville',
                              prefixIcon: Icons.store_rounded,
                              onChanged: (_) {},
                            ),
                          ),
                          if (_nameError != null) _ErrText(_nameError!),
                          const SizedBox(height: 14),

                          // ── Secteur ──────────────────────────────
                          AppFieldLabel('Secteur d\'activité', required: true),
                          const SizedBox(height: 8),
                          _SectorPicker(
                            value: _sector,
                            onChanged: (v) => setState(() => _sector = v),
                          ),
                          const SizedBox(height: 14),

                          // ── Info pays/monnaie déduits automatiquement ─
                          _CountryInfo(country: _country, currency: _currency),
                          const SizedBox(height: 14),

                          // ── Téléphone ────────────────────────────
                          AppLabeledField(
                            label: 'Téléphone de la boutique',
                            child: AppField(
                              controller: _phoneCtrl,
                              isPhone: true,
                              onPhoneChanged: (full, valid) => setState(() {
                                _phoneFull  = full;
                                _phoneValid = valid;
                              }),
                            ),
                          ),
                          const SizedBox(height: 14),

                          // ── Email ────────────────────────────────
                          AppLabeledField(
                            label: 'Email',
                            child: AppField(
                              controller: _emailCtrl,
                              hint: 'Ex: contact@maboutique.com',
                              prefixIcon: Icons.email_outlined,
                              keyboardType: TextInputType.emailAddress,
                              onChanged: (_) {},
                            ),
                          ),
                          if (_emailError != null) _ErrText(_emailError!),
                          const SizedBox(height: 14),

                          // ── Adresse ──────────────────────────────
                          AppLabeledField(
                            label: 'Adresse',
                            child: AppField(
                              controller: _addressCtrl,
                              hint: 'Ex: Rue de la Paix, Douala',
                              prefixIcon: Icons.location_on_outlined,
                            ),
                          ),
                          const SizedBox(height: 28),

                          // ── Bouton créer ─────────────────────────
                          AppPrimaryButton(
                            isLoading: isLoading,
                            enabled: _valid && !isLoading,
                            onTap: _submit,
                            label: l.shopCreate,
                            icon: Icons.storefront_rounded,
                          ),
                          const SizedBox(height: 16),
                          Center(
                            child: GestureDetector(
                              onTap: () => context.pop(),
                              child: Text('← Retour à mes boutiques',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.w500)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
            Positioned(
              top: 12, right: 16,
              child: SafeArea(child: LanguageSwitcher(
                  backgroundColor: Colors.white.withOpacity(0.92))),
            ),
          ]);
        },
      ),
    );
  }
}

// ─── Info pays/monnaie déduits du profil (discret, non modifiable) ───────────
class _CountryInfo extends StatelessWidget {
  final String country, currency;
  const _CountryInfo({required this.country, required this.currency});

  String get _label {
    final c = kCountries.where((c) => c.isoCode == country).firstOrNull;
    final name = c?.nameFr ?? country;
    return '$country — $name · $currency';
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: AppColors.primarySurface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.primary.withOpacity(0.2)),
    ),
    child: Row(children: [
      Icon(Icons.public_rounded, size: 14, color: AppColors.primary),
      const SizedBox(width: 8),
      Expanded(child: Text(_label,
          style: TextStyle(fontSize: 12,
              color: AppColors.primary, fontWeight: FontWeight.w500))),
      Icon(Icons.lock_outline_rounded,
          size: 12, color: AppColors.primary.withOpacity(0.4)),
    ]),
  );
}

// ─── Message d'erreur ─────────────────────────────────────────────────────────
class _ErrText extends StatelessWidget {
  final String message;
  const _ErrText(this.message);
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Text(message,
          style: const TextStyle(fontSize: 10, color: Color(0xFFEF4444))),
    ),
  );
}

// ─── Sélecteur de secteur ─────────────────────────────────────────────────────
class _SectorPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _SectorPicker({required this.value, required this.onChanged});

  static const _sectors = [
    ('retail',      'Commerce',      Icons.storefront_rounded,           Color(0xFF6C3FC7)),
    ('restaurant',  'Restaurant',    Icons.restaurant_rounded,           Color(0xFFEF4444)),
    ('supermarche', 'Supermarché',   Icons.local_grocery_store_rounded,  Color(0xFF10B981)),
    ('pharmacie',   'Pharmacie',     Icons.local_pharmacy_rounded,       Color(0xFF3B82F6)),
    ('ecommerce',   'E-commerce',    Icons.shopping_bag_rounded,         Color(0xFFF59E0B)),
    ('autre',       'Autre',         Icons.store_rounded,                Color(0xFF8B5CF6)),
  ];

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: _sectors.map((s) {
      final (key, label, icon, color) = s;
      final selected = value == key;
      return GestureDetector(
        onTap: () => onChanged(key),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? color.withOpacity(0.10) : const Color(0xFFF9FAFB),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? color : const Color(0xFFE5E7EB),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 15,
                color: selected ? color : const Color(0xFF9CA3AF)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(
                fontSize: 12,
                fontWeight:
                selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? color : const Color(0xFF6B7280))),
          ]),
        ),
      );
    }).toList(),
  );
}