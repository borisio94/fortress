import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../providers/delivery_template_provider.dart';
import '../../domain/entities/delivery_template.dart';
import 'delivery_template_form_sheet.dart';

/// Sheet bottom pour créer ou modifier un emplacement de stock
/// (warehouse ou partner). Les locations type='shop' ne passent pas par ici.
class LocationFormSheet extends ConsumerStatefulWidget {
  final StockLocation? existing;
  final StockLocationType defaultType;
  /// Shop courant. Si fourni ET type=partner, expose un dropdown
  /// "Template de livraison utilisé" listant les templates du shop
  /// (cf. hotfix_049).
  final String? shopId;
  /// Quand `true`, masque le sélecteur de type (Magasin / Dépôt partenaire) :
  /// le type est imposé par `defaultType`. Utilisé quand le formulaire est
  /// ouvert depuis un bouton déjà dédié à un type (ex. « Nouveau dépôt
  /// partenaire ») — proposer « Magasin » y serait trompeur.
  final bool lockType;
  const LocationFormSheet({
    super.key,
    this.existing,
    this.defaultType = StockLocationType.warehouse,
    this.shopId,
    this.lockType = false,
  });

  @override
  ConsumerState<LocationFormSheet> createState() => _LocationFormSheetState();
}

class _LocationFormSheetState extends ConsumerState<LocationFormSheet> {
  late TextEditingController _name;
  late TextEditingController _address;
  /// Ville du dépôt (séparé d'`address` depuis hotfix_051). Affiché
  /// uniquement pour les partenaires — les warehouses gardent `_address`.
  late TextEditingController _city;
  /// Quartier ou zone précise dans la ville.
  late TextEditingController _district;
  late TextEditingController _phone;
  late TextEditingController _contact;
  late TextEditingController _notes;
  late StockLocationType _type;
  late bool _active;
  String? _nameError;
  bool _submitting = false;
  /// `null` = utilise le défaut du shop (cf. hotfix_049). Sinon id d'un
  /// template attribué spécifiquement à ce partenaire.
  String? _deliveryTemplateId;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name    = TextEditingController(text: e?.name ?? '');
    _address = TextEditingController(text: e?.address ?? '');
    _city    = TextEditingController(text: e?.city ?? '');
    _district= TextEditingController(text: e?.district ?? '');
    _phone   = TextEditingController(text: e?.phone ?? '');
    _contact = TextEditingController(text: e?.contactName ?? '');
    _notes   = TextEditingController(text: e?.notes ?? '');
    _type    = e?.type ?? widget.defaultType;
    _active  = e?.isActive ?? true;
    _deliveryTemplateId = e?.deliveryTemplateId;
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _city.dispose();
    _district.dispose();
    _phone.dispose();
    _contact.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? _validateName(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Nom requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    if (s.length > 60) return 'Maximum 60 caractères';
    // Unicité par propriétaire, tous types confondus, insensible à la casse.
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final lower = s.toLowerCase();
    final editingId = widget.existing?.id;
    // 1. StockLocations (warehouses/partners + StockLocation type=shop).
    final siblings = AppDatabase.getStockLocationsForOwner(userId);
    final dup = siblings.any((l) =>
        l.id != editingId && l.name.trim().toLowerCase() == lower);
    if (dup) return 'Un emplacement portant ce nom existe déjà';
    // 2. Boutiques (filet : couvre le cas où la StockLocation type=shop
    //    associée n'a pas encore été synchronisée localement).
    final shops = LocalStorageService.getShopsForUser(userId);
    final dupShop = shops.any((sh) =>
        sh.name.trim().toLowerCase() == lower);
    if (dupShop) return 'Une boutique porte déjà ce nom';
    return null;
  }

  Future<void> _submit() async {
    final err = _validateName(_name.text);
    if (err != null) {
      setState(() => _nameError = err);
      return;
    }
    setState(() {
      _submitting = true;
      _nameError = null;
    });

    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    if (userId.isEmpty) {
      setState(() { _submitting = false; _nameError = 'Connexion requise'; });
      return;
    }

    // ── Garde quota plan (création uniquement) ────────────────────────
    // Partenaires & magasins = totaux par compte.
    if (!_isEdit) {
      final plan = ref.read(currentPlanProvider);
      final locs = AppDatabase.getStockLocationsForOwner(userId);
      if (_type == StockLocationType.partner) {
        final n = locs.where((l) => l.type == StockLocationType.partner).length;
        if (!plan.canAddPartner(n)) {
          setState(() => _submitting = false);
          AppSnack.error(context,
              'Limite de partenaires atteinte (${plan.maxPartnerDepots}) pour '
              'votre plan. Passez à un plan supérieur pour en ajouter.');
          return;
        }
      } else if (_type == StockLocationType.warehouse) {
        final n = locs.where((l) => l.type == StockLocationType.warehouse).length;
        if (!plan.canAddWarehouse(n)) {
          setState(() => _submitting = false);
          AppSnack.error(context,
              'Limite de magasins atteinte (${plan.maxWarehouses}) pour votre '
              'plan. Passez à un plan supérieur pour en ajouter.');
          return;
        }
      }
    }

    // Le contact partenaire est désormais un simple numéro WhatsApp (champ
    // phone). L'éventuel `whatsappGroupUrl` legacy d'un partenaire existant
    // est préservé tel quel (non modifié par ce formulaire).
    final isPartner = _type == StockLocationType.partner;
    final phone     = _phone.text.trim();
    // Pour les partenaires : ville/quartier séparés. Les warehouses
    // continuent à utiliser le champ `address` legacy.
    final cityVal     = isPartner ? _city.text.trim() : '';
    final districtVal = isPartner ? _district.text.trim() : '';
    final loc = (widget.existing ?? StockLocation(
          id: 'loc_${DateTime.now().millisecondsSinceEpoch}_'
              '${_type.key}',
          ownerId: userId,
          type: _type,
          name: _name.text.trim(),
          createdAt: DateTime.now(),
        )).copyWith(
          name:        _name.text.trim(),
          address:     _address.text.trim().isEmpty ? null : _address.text.trim(),
          city:        cityVal.isEmpty ? null : cityVal,
          clearCity:   isPartner && cityVal.isEmpty,
          district:    districtVal.isEmpty ? null : districtVal,
          clearDistrict: isPartner && districtVal.isEmpty,
          phone:       phone.isEmpty ? null : phone,
          clearPhone:  phone.isEmpty,
          contactName: _contact.text.trim().isEmpty ? null : _contact.text.trim(),
          notes:       _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          isActive:    _active,
          deliveryTemplateId: _deliveryTemplateId,
        );

    try {
      await AppDatabase.saveStockLocation(loc);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        AppSnack.error(context,
            'Erreur lors de l\'enregistrement : ${e.toString().replaceAll('Exception: ', '')}');
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final headerTitle = _isEdit
        ? 'Modifier l\'emplacement'
        : (_type == StockLocationType.warehouse
            ? 'Nouveau magasin'
            : 'Nouveau dépôt partenaire');
    return AdaptiveFormFrame(
      title: headerTitle,
      icon: _isEdit
          ? Icons.edit_outlined
          : (_type == StockLocationType.warehouse
              ? Icons.warehouse_outlined
              : Icons.store_outlined),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

                // Type (verrouillé en édition, ou quand imposé par l'appelant
                // ex. création depuis le bouton « Nouveau dépôt partenaire »)
                if (!_isEdit && !widget.lockType) ...[
                  const _Label('Type'),
                  const SizedBox(height: 6),
                  _TypePicker(
                    value: _type,
                    onChanged: (v) => setState(() => _type = v),
                  ),
                  const SizedBox(height: 14),
                ],

                const _Label('Nom', required: true),
                const SizedBox(height: 4),
                _Field(
                  controller: _name,
                  hint: _type == StockLocationType.warehouse
                      ? 'Ex: Magasin Akwa'
                      : 'Ex: Dépôt DHL Douala',
                  icon: Icons.badge_outlined,
                  errorText: _nameError,
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                ),
                const SizedBox(height: 12),

                // Pour les partenaires : ville et quartier séparés
                // (cf. hotfix_051). Les warehouses gardent l'adresse libre.
                if (_type == StockLocationType.partner) ...[
                  const _Label('Ville'),
                  const SizedBox(height: 4),
                  _Field(
                    controller: _city,
                    hint: 'Ex: Yaoundé',
                    icon: Icons.location_city_outlined,
                  ),
                  const SizedBox(height: 12),
                  const _Label('Quartier'),
                  const SizedBox(height: 4),
                  _Field(
                    controller: _district,
                    hint: 'Ex: Bastos',
                    icon: Icons.maps_home_work_outlined,
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  const _Label('Adresse'),
                  const SizedBox(height: 4),
                  _Field(
                    controller: _address,
                    hint: 'Rue, quartier, ville',
                    icon: Icons.location_on_outlined,
                  ),
                  const SizedBox(height: 12),
                ],

                // Partenaire : contact WhatsApp (numéro). Les warehouses
                // gardent le libellé « Téléphone ».
                if (_type == StockLocationType.partner) ...[
                  const _Label('Contact WhatsApp'),
                  const SizedBox(height: 4),
                  AppField(
                    controller: _phone,
                    isPhone: true,
                    style: AppFieldStyle.filled,
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  const _Label('Téléphone'),
                  const SizedBox(height: 4),
                  AppField(
                    controller: _phone,
                    isPhone: true,
                    style: AppFieldStyle.filled,
                  ),
                  const SizedBox(height: 12),
                ],

                const _Label('Personne contact'),
                const SizedBox(height: 4),
                _Field(
                  controller: _contact,
                  hint: 'Responsable ou référent sur place',
                  icon: Icons.person_outline_rounded,
                ),
                const SizedBox(height: 12),

                const _Label('Notes'),
                const SizedBox(height: 4),
                _Field(
                  controller: _notes,
                  hint: 'Horaires, contraintes, infos utiles…',
                  icon: Icons.sticky_note_2_outlined,
                  maxLines: 2,
                ),
                const SizedBox(height: 12),

                // Dropdown template livraison — uniquement pour les
                // partenaires d'un shop donné (cf. hotfix_049 + hotfix_093).
                // Le picker groupe : templates spécifiques à ce partenaire
                // en haut, templates shop-wide en dessous. `null` = laisse
                // la résolution automatique choisir (défaut partenaire >
                // défaut shop).
                if (_type == StockLocationType.partner
                    && widget.shopId != null) ...[
                  const _Label('Template de livraison'),
                  const SizedBox(height: 4),
                  _DeliveryTemplatePicker(
                    shopId: widget.shopId!,
                    partnerId: widget.existing?.id,
                    selectedId: _deliveryTemplateId,
                    onChanged: (v) =>
                        setState(() => _deliveryTemplateId = v),
                  ),
                  const SizedBox(height: 12),
                ],

                if (_isEdit)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _active,
                    onChanged: (v) => setState(() => _active = v),
                    title: const Text('Actif',
                        style: AppTextStyles.bodyBold),
                    subtitle: Text(_active
                            ? 'Disponible dans les sélections'
                            : 'Masqué des sélections',
                        style: AppTextStyles.caption.copyWith(
                            color: AppColors.textHint)),
                  ),
                const SizedBox(height: 8),

                Row(children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _submitting
                          ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Annuler'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryFill,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _submitting
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_isEdit ? 'Enregistrer' : 'Créer'),
                    ),
                  ),
                ]),
          ],
        ),
      ),
    );
  }
}

// ─── Widgets locaux ──────────────────────────────────────────────────────────
class _Label extends StatelessWidget {
  final String text;
  final bool required;
  const _Label(this.text, {this.required = false});
  @override
  Widget build(BuildContext context) => RichText(
    text: TextSpan(
      style: AppTextStyles.caption,
      children: [
        TextSpan(text: text),
        if (required) const TextSpan(text: ' *',
            style: TextStyle(color: Color(0xFFEF4444),
                fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final int maxLines;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    this.maxLines = 1,
    this.errorText,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    maxLines: maxLines,
    onChanged: onChanged,
    style: AppTextStyles.body,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: AppTextStyles.bodySm.copyWith(color: const Color(0xFFBBBBBB)),
      prefixIcon: Icon(icon, size: 15, color: const Color(0xFFAAAAAA)),
      filled: true, fillColor: AppColors.inputFill, isDense: true,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      errorText: errorText,
    ),
  );
}

class _TypePicker extends StatelessWidget {
  final StockLocationType value;
  final ValueChanged<StockLocationType> onChanged;
  const _TypePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(
      child: _TypeOption(
        label: 'Magasin',
        icon: Icons.warehouse_rounded,
        color: const Color(0xFF0EA5E9),
        selected: value == StockLocationType.warehouse,
        onTap: () => onChanged(StockLocationType.warehouse),
      ),
    ),
    const SizedBox(width: 8),
    Expanded(
      child: _TypeOption(
        label: 'Dépôt partenaire',
        icon: Icons.local_shipping_rounded,
        color: const Color(0xFFF59E0B),
        selected: value == StockLocationType.partner,
        onTap: () => onChanged(StockLocationType.partner),
      ),
    ),
  ]);
}

class _TypeOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _TypeOption({
    required this.label, required this.icon,
    required this.color, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha:0.10) : AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? color : Theme.of(context).semantic.borderSubtle,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 15,
            color: selected ? color : AppColors.textHint),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodySm.copyWith(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? color : AppColors.textSecondary)),
        ),
      ]),
    ),
  );
}

/// Valeur sentinelle de l'item « Créer un nouveau template » du dropdown.
/// Jamais persistée : interceptée par [_DeliveryTemplatePicker._handleChanged].
const String _kCreateTplValue = '__create_new_delivery_template__';

/// Dropdown de sélection de template de livraison pour un partenaire.
/// La valeur `null` correspond à "Template par défaut du shop".
/// Le dernier item permet de créer un template à la volée et de l'affecter.
class _DeliveryTemplatePicker extends ConsumerWidget {
  final String          shopId;
  /// Id du partenaire courant (StockLocation.id). Null en création :
  /// dans ce cas, seuls les templates shop-wide sont proposés (un
  /// template partenaire ne peut être créé qu'après que le partenaire
  /// existe — chicken-and-egg sinon avec le FK partner_id).
  final String?         partnerId;
  final String?         selectedId;
  final ValueChanged<String?> onChanged;
  const _DeliveryTemplatePicker({
    required this.shopId,
    required this.partnerId,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(deliveryTemplatesProvider(shopId));
    return asyncList.when(
      loading: () => const SizedBox(
        height: 38,
        child: Center(child: SizedBox(width: 16, height: 16,
            child: CircularProgressIndicator(strokeWidth: 1.8))),
      ),
      error: (e, _) => Text(e.toString(),
          style: AppTextStyles.caption.copyWith(color: AppColors.error)),
      data: (list) {
        // Templates spécifiques à ce partenaire (haut) et shop-wide (bas).
        // La règle de résolution côté send (DeliveryTemplateRepository.
        // resolveForRecipient) privilégie déjà le défaut partenaire si
        // selectedId est null — ce picker permet juste de FORCER un
        // template précis quand on veut.
        final partnerTpls = partnerId == null
            ? const <DeliveryTemplate>[]
            : list.where((t) => t.partnerId == partnerId).toList();
        final shopTpls = list.where((t) => t.partnerId == null).toList();

        final items = <DropdownMenuItem<String?>>[
          const DropdownMenuItem<String?>(
            value: null,
            child: Text('Auto (défaut partenaire ou shop)',
                style: AppTextStyles.bodySm),
          ),
          if (partnerTpls.isNotEmpty)
            ...partnerTpls.map((t) => DropdownMenuItem<String?>(
                  value: t.id,
                  child: Row(children: [
                    // local_shipping plutôt que handshake — cf.
                    // project_icon_tree_shaking.
                    Icon(Icons.local_shipping_outlined, size: 13,
                        color: AppColors.primary),
                    const SizedBox(width: 6),
                    Flexible(child: Text(
                        '${t.name}${t.isDefault ? " ★" : ""}',
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodySm)),
                  ]),
                )),
          ...shopTpls.map((t) => DropdownMenuItem<String?>(
                value: t.id,
                child: Row(children: [
                  Icon(Icons.store_outlined, size: 13,
                      color: AppColors.textHint),
                  const SizedBox(width: 6),
                  Flexible(child: Text(
                      '${t.name}${t.isDefault ? " ★" : ""}',
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodySm)),
                ]),
              )),
          // Action en bas de liste : créer un nouveau template et l'affecter
          // immédiatement au partenaire en cours (cf. _handleChanged).
          DropdownMenuItem<String?>(
            value: _kCreateTplValue,
            child: Row(children: [
              Icon(Icons.add_circle_outline_rounded, size: 14,
                  color: AppColors.primary),
              const SizedBox(width: 6),
              Text('Créer un nouveau template',
                  style: AppTextStyles.bodySm.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).semantic.borderSubtle),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              isExpanded: true,
              value: list.any((t) => t.id == selectedId)
                  ? selectedId
                  : null,
              icon: Icon(Icons.keyboard_arrow_down_rounded,
                  size: 18, color: AppColors.textHint),
              items: items,
              onChanged: (v) => _handleChanged(context, ref, list, v),
            ),
          ),
        );
      },
    );
  }

  /// Intercepte la sélection du dropdown. Si l'utilisateur choisit « Créer un
  /// nouveau template », ouvre le formulaire de template, puis sélectionne
  /// automatiquement le template fraîchement créé (= l'affecte au partenaire
  /// via `deliveryTemplateId`). Sinon, propage simplement la sélection.
  ///
  /// FK-safe : à la CRÉATION d'un partenaire (`partnerId == null`), le template
  /// est créé shop-wide (le partenaire n'existe pas encore en base, donc on ne
  /// peut pas le scoper avec un FK partner_id). En ÉDITION d'un partenaire
  /// existant, il est pré-scopé à ce partenaire.
  Future<void> _handleChanged(BuildContext context, WidgetRef ref,
      List<DeliveryTemplate> current, String? v) async {
    if (v != _kCreateTplValue) {
      onChanged(v);
      return;
    }
    final beforeIds = current.map((t) => t.id).toSet();
    final saved = await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => DeliveryTemplateFormSheet(
        shopId: shopId,
        initialPartnerId: partnerId,
      ),
    );
    if (saved != true) return;
    final after = ref.read(deliveryTemplatesProvider(shopId)).valueOrNull
        ?? const <DeliveryTemplate>[];
    final created =
        after.where((t) => !beforeIds.contains(t.id)).toList();
    if (created.isNotEmpty) onChanged(created.first.id);
  }
}
