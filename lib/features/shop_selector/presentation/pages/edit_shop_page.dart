import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../bloc/shop_selector_bloc.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/config/restaurant_mode.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/country_phone_data.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/widgets/fortress_logo.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/language_switcher.dart';
import '../../domain/usecases/update_shop_usecase.dart';
import '../../domain/entities/shop_summary.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';

class EditShopPage extends ConsumerStatefulWidget {
  final String shopId;
  const EditShopPage({super.key, required this.shopId});

  @override
  ConsumerState<EditShopPage> createState() => _EditShopPageState();
}

class _EditShopPageState extends ConsumerState<EditShopPage> {
  final _nameCtrl  = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _waCtrl    = TextEditingController();
  final _emailCtrl = TextEditingController();

  String _sector   = 'retail';
  String _country  = 'CM';
  String _currency = 'XAF';

  String? _nameError;
  String? _emailError;
  bool _initialized = false;

  // Valeurs d'origine — pour détecter les vraies modifications
  late String _origName, _origSector, _origPhone, _origWa, _origEmail;

  // Magasin parent (warehouse) + source de la boutique
  List<StockLocation> _warehouses = [];
  StockLocation? _shopLocation;
  String? _parentWarehouseId;
  String? _origParentWarehouseId;

  @override
  void initState() {
    super.initState();
    // Pré-remplir depuis Hive (synchrone) puis depuis le provider si disponible
    final cached = LocalStorageService.getShop(widget.shopId);
    if (cached != null) _hydrate(cached);
    _loadLocations();
    // Sync locations en arrière-plan
    AppDatabase.syncStockLocations().then((_) {
      if (mounted) _loadLocations();
    });
  }

  /// Charge depuis Hive la liste des warehouses actifs + la location de la
  /// boutique courante (pour lire le parentWarehouseId actuel).
  void _loadLocations() {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    if (userId.isEmpty) return;
    final all = AppDatabase.getStockLocationsForOwner(userId);
    final shopLoc = AppDatabase.getShopLocation(widget.shopId);
    setState(() {
      _warehouses = all
          .where((l) => l.type == StockLocationType.warehouse && l.isActive)
          .toList();
      _shopLocation = shopLoc;
      // Initialiser la valeur si pas déjà modifiée par l'utilisateur
      if (_origParentWarehouseId == null) {
        _parentWarehouseId = shopLoc?.parentWarehouseId;
        _origParentWarehouseId = shopLoc?.parentWarehouseId ?? '';
      }
    });
  }

  void _hydrate(ShopSummary s) {
    if (_initialized) return;
    _nameCtrl.text  = s.name;
    _phoneCtrl.text = s.phone ?? '';
    _waCtrl.text    = s.whatsappPhone ?? '';
    _emailCtrl.text = s.email ?? '';
    _sector   = s.sector;
    _country  = s.country;
    _currency = s.currency;
    _origName   = s.name;
    _origSector = s.sector;
    _origPhone  = s.phone ?? '';
    _origWa     = s.whatsappPhone ?? '';
    _origEmail  = s.email ?? '';
    _initialized = true;

    _nameCtrl.addListener(() => setState(() =>
        _nameError = _validateName(_nameCtrl.text)));
    _emailCtrl.addListener(() => setState(() =>
        _emailError = _validateEmail(_emailCtrl.text)));
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _waCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  static String? _validateName(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Nom requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    if (s.length > 60) return 'Maximum 60 caractères';
    return null;
  }

  static String? _validateEmail(String v) {
    final s = v.trim();
    if (s.isEmpty) return null;
    if (!RegExp(r'^[\w._%+\-]+@[\w.\-]+\.[a-zA-Z]{2,}$').hasMatch(s))
      return 'Email invalide';
    return null;
  }

  // `_sector` ne figure plus dans la détection de changement : il est figé
  // à la création et ne peut donc jamais différer de `_origSector`.
  bool get _hasChanges =>
      _nameCtrl.text.trim()  != _origName.trim()   ||
      _phoneCtrl.text.trim() != _origPhone.trim()  ||
      _waCtrl.text.trim()    != _origWa.trim()     ||
      _emailCtrl.text.trim() != _origEmail.trim()  ||
      (_parentWarehouseId ?? '') != (_origParentWarehouseId ?? '');

  bool get _hasShopFieldChanges =>
      _nameCtrl.text.trim()  != _origName.trim()   ||
      _phoneCtrl.text.trim() != _origPhone.trim()  ||
      _waCtrl.text.trim()    != _origWa.trim()     ||
      _emailCtrl.text.trim() != _origEmail.trim();

  bool get _hasParentChange =>
      (_parentWarehouseId ?? '') != (_origParentWarehouseId ?? '');

  bool get _valid =>
      _validateName(_nameCtrl.text) == null &&
      _validateEmail(_emailCtrl.text) == null;

  /// Construit un UpdateShopParams ne contenant QUE les champs modifiés.
  UpdateShopParams _buildParams() {
    final name  = _nameCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final wa    = _waCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    return UpdateShopParams(
      shopId:   widget.shopId,
      name:     name  != _origName.trim()   ? name  : null,
      // `sector` JAMAIS envoyé : figé à la création. Le retirer ici et pas
      // seulement de l'UI est ce qui rend le verrou réel — sinon un état
      // résiduel ou un futur widget rebrancherait la modification sans que
      // personne ne s'en aperçoive.
      // Pays/monnaie non modifiables ici (cohérent avec CreateShopPage)
      phone:    phone != _origPhone.trim()  ? phone : null,
      whatsappPhone: wa != _origWa.trim()   ? wa : null,
      email:    email != _origEmail.trim()  ? email : null,
    );
  }

  /// Persiste le warehouse parent sur la location de la boutique. Retourne
  /// true si OK (ou si rien à changer). Cette opération est distincte de
  /// l'update du Shop — elle cible `stock_locations`.
  Future<bool> _persistParentWarehouse() async {
    if (!_hasParentChange) return true;
    final loc = _shopLocation;
    if (loc == null) {
      // Pas de location type=shop en base → la migration ne s'est pas encore
      // faite (probable pour une boutique toute neuve). On skippe en silence.
      return true;
    }
    try {
      final updated = loc.copyWith(
        parentWarehouseId: _parentWarehouseId ?? '',
      );
      // copyWith traite '' comme "pas de valeur" → on force null pour délier.
      final finalLoc = _parentWarehouseId == null || _parentWarehouseId!.isEmpty
          ? StockLocation(
              id: loc.id,
              ownerId: loc.ownerId,
              type: loc.type,
              name: loc.name,
              shopId: loc.shopId,
              parentWarehouseId: null,
              address: loc.address,
              phone: loc.phone,
              contactName: loc.contactName,
              notes: loc.notes,
              isActive: loc.isActive,
              createdAt: loc.createdAt,
            )
          : updated;
      await AppDatabase.saveStockLocation(finalLoc);
      return true;
    } catch (e) {
      if (mounted) {
        AppSnack.error(context,
            'Erreur lors de l\'enregistrement du magasin parent : '
            '${e.toString().replaceAll('Exception: ', '')}');
      }
      return false;
    }
  }

  Future<void> _submit() async {
    setState(() {
      _nameError  = _validateName(_nameCtrl.text);
      _emailError = _validateEmail(_emailCtrl.text);
    });
    if (!_valid || !_hasChanges) return;

    // Si seul le magasin parent change, on ne déclenche pas l'update shop.
    if (_hasShopFieldChanges) {
      // L'update du Shop passera par le BlocListener (ShopUpdated).
      // Le warehouse parent sera persisté à l'arrivée de ce state.
      context.read<ShopSelectorBloc>().add(UpdateShopRequested(_buildParams()));
    } else if (_hasParentChange) {
      final ok = await _persistParentWarehouse();
      if (ok && mounted) {
        setState(() {
          _origParentWarehouseId = _parentWarehouseId ?? '';
        });
        AppSnack.success(context, 'Magasin parent mis à jour');
        context.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fallback : si le cache Hive n'a pas pré-rempli, essayer via provider
    if (!_initialized) {
      final fromProvider = ref.watch(currentShopProvider);
      if (fromProvider != null && fromProvider.id == widget.shopId) {
        _hydrate(fromProvider);
      }
    }

    return Scaffold(
      backgroundColor: AppColors.primarySurface,
      body: BlocConsumer<ShopSelectorBloc, ShopSelectorState>(
        listener: (context, state) async {
          if (state is ShopUpdated) {
            // Mettre à jour les providers : liste + boutique courante si c'est celle-ci
            ref.read(myShopsProvider.notifier).updateShop(state.shop);
            final current = ref.read(currentShopProvider);
            if (current?.id == state.shop.id) {
              ref.read(currentShopProvider.notifier).setShop(state.shop);
            }
            ActivityLogService.log(
              action:      'shop_updated',
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
            // Persister aussi le warehouse parent s'il a changé
            if (_hasParentChange) {
              await _persistParentWarehouse();
            }
            if (!context.mounted) return;
            AppSnack.success(context, '${state.shop.name} modifiée avec succès');
            context.pop();
          }
          if (state is ShopSelectorError) {
            AppSnack.error(context, state.message);
          }
        },
        builder: (context, state) {
          if (!_initialized) {
            return const Center(child: CircularProgressIndicator());
          }
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
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(20)) : null,
                      color: isDesktop ? null : AppColors.surface,
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
                                  color: AppColors.inputFill,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(Icons.close,
                                    size: 16, color: AppColors.textSecondary),
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
                              child: Icon(Icons.edit_rounded,
                                  size: 24, color: AppColors.primary),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Center(child: Text('Modifier la boutique',
                              style: AppTextStyles.title.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.onSurface))),
                          const SizedBox(height: 4),
                          Center(child: Text(
                              'Mettez à jour les informations de votre boutique',
                              style: AppTextStyles.bodySm.copyWith(
                                  color: AppColors.textSecondary))),
                          const SizedBox(height: 28),

                          // ── Nom boutique ─────────────────────────
                          AppLabeledField(
                            label: 'Nom de la boutique', required: true,
                            child: AppField(
                              controller: _nameCtrl,
                              hint: 'Ex: Mon Magasin Centre-ville',
                              prefixIcon: Icons.store_rounded,
                            ),
                          ),
                          if (_nameError != null) _ErrText(_nameError!),
                          const SizedBox(height: 14),

                          // ── Type d'établissement (LECTURE SEULE) ─
                          // Figé à la création : il détermine toute
                          // l'ergonomie (caisse e-commerce ou service en
                          // salle). Le basculer sur une boutique en
                          // exploitation laisserait des données orphelines
                          // — commandes rattachées à des tables sur une
                          // boutique devenue e-commerce, plan de salle
                          // inaccessible. Cf. kCreationSectors.
                          _ReadOnlyInfo(
                            icon: Icons.storefront_outlined,
                            label: 'Type d\'établissement',
                            value: establishmentLabel(_sector),
                          ),
                          const SizedBox(height: 14),

                          // ── Pays / monnaie (lecture seule) ───────
                          _CountryInfo(country: _country, currency: _currency),
                          const SizedBox(height: 14),

                          // ── Téléphone ────────────────────────────
                          AppLabeledField(
                            label: 'Téléphone de la boutique',
                            child: AppField(
                              controller: _phoneCtrl,
                              isPhone: true,
                              onPhoneChanged: (_, __) => setState(() {}),
                            ),
                          ),
                          const SizedBox(height: 14),

                          // ── Numéro WhatsApp dédié ────────────────
                          AppLabeledField(
                            label: 'Numéro WhatsApp (commandes)',
                            child: AppField(
                              controller: _waCtrl,
                              isPhone: true,
                              onPhoneChanged: (_, __) => setState(() {}),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 4, left: 2),
                            child: Text(
                              'Numéro qui reçoit les conversations du '
                              'catalogue et des commandes. Laisser vide '
                              'pour utiliser le téléphone de la boutique.',
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.textHint),
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
                            ),
                          ),
                          if (_emailError != null) _ErrText(_emailError!),
                          const SizedBox(height: 14),

                          // ── Magasin parent ───────────────────────
                          AppFieldLabel('Magasin parent'),
                          const SizedBox(height: 6),
                          _WarehousePicker(
                            warehouses: _warehouses,
                            value: _parentWarehouseId,
                            onChanged: (id) =>
                                setState(() => _parentWarehouseId = id),
                          ),
                          const SizedBox(height: 28),

                          // ── Bouton enregistrer ──────────────────
                          AppPrimaryButton(
                            isLoading: isLoading,
                            enabled: _valid && _hasChanges && !isLoading,
                            onTap: _submit,
                            label: 'Enregistrer',
                            icon: Icons.check_rounded,
                          ),
                          const SizedBox(height: 16),
                          Center(
                            child: GestureDetector(
                              onTap: () => context.pop(),
                              child: Text('← Annuler',
                                  style: AppTextStyles.bodySm.copyWith(
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
                  backgroundColor: Colors.white.withValues(alpha:0.92))),
            ),
          ]);
        },
      ),
    );
  }
}

// ─── Info pays/monnaie (lecture seule) ───────────────────────────────────────
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
      border: Border.all(color: AppColors.primary.withValues(alpha:0.2)),
    ),
    child: Row(children: [
      Icon(Icons.public_rounded, size: 14, color: AppColors.primary),
      const SizedBox(width: 8),
      Expanded(child: Text(_label,
          style: AppTextStyles.bodySm.copyWith(
              color: AppColors.primary, fontWeight: FontWeight.w500))),
      Icon(Icons.lock_outline_rounded,
          size: 12, color: AppColors.primary.withValues(alpha:0.4)),
    ]),
  );
}

/// Champ non modifiable, avec cadenas — même présentation que
/// [_CountryInfo] pour que « figé » se lise de la même façon partout.
class _ReadOnlyInfo extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _ReadOnlyInfo({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
    decoration: BoxDecoration(
      color: AppColors.primarySurface,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
    ),
    child: Row(children: [
      Icon(icon, size: 14, color: AppColors.primary),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: AppTextStyles.micro.copyWith(
                    color: AppColors.primary.withValues(alpha: 0.7))),
            Text(value,
                style: AppTextStyles.bodySm.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      Icon(Icons.lock_outline_rounded,
          size: 12, color: AppColors.primary.withValues(alpha: 0.4)),
    ]),
  );
}

class _ErrText extends StatelessWidget {
  final String message;
  const _ErrText(this.message);
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.only(top: 4, left: 2),
      child: Text(message,
          style: AppTextStyles.micro.copyWith(
              color: const Color(0xFFEF4444))),
    ),
  );
}
// ─── Sélecteur de magasin parent ─────────────────────────────────────────────
class _WarehousePicker extends StatelessWidget {
  final List<StockLocation> warehouses;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _WarehousePicker({
    required this.warehouses,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (warehouses.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.divider),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded,
              size: 14, color: AppColors.textHint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
                'Aucun magasin créé. Va dans Paramètres → Emplacements de stock '
                'pour créer un magasin central qui approvisionnera cette boutique.',
                style: AppTextStyles.caption.copyWith(
                    color: AppColors.textSecondary)),
          ),
        ]),
      );
    }

    // Items : "Aucun" + les warehouses actifs. On évite Flexible/Expanded
    // dans les Row de DropdownMenuItem (casse la mesure quand le dropdown
    // n'a pas encore de contraintes de largeur).
    final items = <DropdownMenuItem<String?>>[
      DropdownMenuItem<String?>(
        value: null,
        child: Text('— Aucun (boutique indépendante) —',
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body.copyWith(
                color: AppColors.textSecondary)),
      ),
      ...warehouses.map((w) => DropdownMenuItem<String?>(
            value: w.id,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.warehouse_rounded,
                    size: 14, color: AppColors.info),
                const SizedBox(width: 8),
                Text(w.name,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body.copyWith(
                        color: AppColors.onSurface)),
              ],
            ),
          )),
    ];

    return DropdownButtonFormField<String?>(
      value: warehouses.any((w) => w.id == value) ? value : null,
      items: items,
      onChanged: onChanged,
      isDense: true,
      isExpanded: true, // indispensable avec des items à largeur variable
      icon: Icon(Icons.arrow_drop_down_rounded,
          color: AppColors.textHint),
      decoration: InputDecoration(
        filled: true,
        fillColor: AppColors.inputFill,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.divider)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.divider)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      ),
    );
  }
}
