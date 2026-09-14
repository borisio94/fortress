import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/delivery_zone_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/dimens.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../crm/domain/entities/client.dart';
import '../../../crm/presentation/pages/clients_page.dart' show ClientFormSheet;
import '../../../parametres/domain/entities/delivery_quartier.dart';
import '../../../parametres/domain/entities/delivery_zone.dart';
import '../../domain/entities/sale.dart' show DeliveryMode;

/// Résultat du sheet "Enregistrer commande" (sprint UX commande).
/// Capture les 3 informations minimales pour qu'une commande puisse être
/// enregistrée en statut `scheduled` :
///   * Le client (sélectionné ou créé)
///   * La date de livraison souhaitée
///   * Le lieu de livraison (ville + quartier), pré-rempli depuis le client
///     mais modifiable. Le snapshot reste figé sur la commande, et la
///     fiche client est mise à jour silencieusement à la nouvelle adresse
///     si modifiée (cf. _onSaveOrder dans le bloc).
class OrderCreationResult {
  final Client    client;
  final DateTime? scheduledAt;
  final String?   deliveryCity;
  final String?   deliveryAddress;
  /// Date à laquelle la commande a été effectivement passée. Par défaut
  /// `DateTime.now()`. Antidatable (sans limite passée) pour permettre la
  /// saisie de ventes effectuées hors-ligne / oubliées / en retard.
  /// Maps sur `Sale.createdAt` côté bloc.
  final DateTime  createdAt;
  /// Montant déjà encaissé par la boutique au moment de la création.
  /// Permet de capturer un acompte client (paiement partiel) OU un
  /// paiement total upfront sans devoir ouvrir un dialog supplémentaire
  /// après création. `0` = aucun versement (la commande naît `unpaid`).
  final double    amountPaid;
  /// Vente « à choisir sur place » : le livreur emporte plusieurs articles,
  /// le client en garde certains, le reste revient. Si `true`, le stock est
  /// réservé à la création puis réconcilié à la clôture de la tournée.
  final bool      isApprovalSale;
  /// Frais de livraison par quartier (PR-2). `deliveryPrice` MAJORE le total
  /// facturé. `deliveryQuartier`/`deliveryZone` figés sur la commande.
  final double    deliveryPrice;
  final String?   deliveryQuartier;
  final String?   deliveryZone;
  const OrderCreationResult({
    required this.client,
    required this.scheduledAt,
    required this.deliveryCity,
    required this.deliveryAddress,
    required this.createdAt,
    this.amountPaid = 0,
    this.isApprovalSale = false,
    this.deliveryPrice = 0,
    this.deliveryQuartier,
    this.deliveryZone,
  });
}

/// Helper d'ouverture standardisé.
/// `orderTotal` (optionnel) : si fourni, débloque le champ "Acompte versé"
/// qui permet de saisir un paiement partiel ou total à la création (sans
/// passer par un dialog acompte ultérieur). Cap au total.
Future<OrderCreationResult?> showOrderCreationSheet(
  BuildContext context, {
  required String shopId,
  Client?   initialClient,
  DateTime? initialDate,
  String?   initialCity,
  String?   initialAddress,
  DateTime? initialCreatedAt,
  double?   orderTotal,
  bool      initialIsApprovalSale = false,
  bool      lockApproval = false,
  // FIX 2 — mode de livraison courant (set par les chips / « Détails de
  // livraison »). Si `pickup`, les champs ville/quartier sont masqués et non
  // exigés (retrait en boutique = pas d'adresse). `null` ou tout autre mode →
  // comportement historique (ville/quartier requis).
  DeliveryMode? deliveryMode,
  // Livraison par quartier (PR-2) — pré-remplissage en édition.
  double?   initialDeliveryPrice,
  String?   initialQuartier,
  String?   initialZone,
}) {
  return showFormSheet<OrderCreationResult>(
    context: context,
    builder: (_) => _OrderCreationSheet(
      shopId:           shopId,
      initialClient:    initialClient,
      initialDate:      initialDate,
      initialCity:      initialCity,
      initialAddress:   initialAddress,
      initialCreatedAt: initialCreatedAt,
      orderTotal:       orderTotal,
      initialIsApprovalSale: initialIsApprovalSale,
      lockApproval:          lockApproval,
      deliveryMode:          deliveryMode,
      initialDeliveryPrice:  initialDeliveryPrice,
      initialQuartier:       initialQuartier,
      initialZone:           initialZone,
    ),
  );
}

class _OrderCreationSheet extends StatefulWidget {
  final String shopId;
  final Client?   initialClient;
  final DateTime? initialDate;
  final String?   initialCity;
  final String?   initialAddress;
  final DateTime? initialCreatedAt;
  final double?   orderTotal;
  final bool      initialIsApprovalSale;
  final bool      lockApproval;
  final DeliveryMode? deliveryMode;
  final double?   initialDeliveryPrice;
  final String?   initialQuartier;
  final String?   initialZone;
  const _OrderCreationSheet({
    required this.shopId,
    this.initialClient,
    this.initialDate,
    this.initialCity,
    this.initialAddress,
    this.initialCreatedAt,
    this.orderTotal,
    this.initialIsApprovalSale = false,
    this.lockApproval = false,
    this.deliveryMode,
    this.initialDeliveryPrice,
    this.initialQuartier,
    this.initialZone,
  });
  @override
  State<_OrderCreationSheet> createState() => _OrderCreationSheetState();
}

class _OrderCreationSheetState extends State<_OrderCreationSheet> {
  /// Délai par défaut entre l'heure de commande et l'heure de livraison.
  /// Une commande neuve arrive donc pré-remplie à `_createdAt + 1 h` au
  /// lieu d'un champ vide qui bloquait `_confirm` tant qu'on n'avait pas
  /// ouvert les deux pickers.
  static const Duration _kDeliveryLead = Duration(hours: 1);

  Client? _client;
  DateTime? _date;

  /// `true` dès que l'heure de livraison a été fixée à la main (picker ou
  /// croix d'effacement), ou héritée d'une commande existante.
  ///
  /// Tant que c'est `false`, `_date` SUIT `_createdAt + 1 h` : antidater la
  /// commande décale la livraison avec elle. Une fois l'utilisateur passé
  /// par le picker, on ne touche plus à son choix — sinon changer la date
  /// de commande écraserait silencieusement une heure de livraison
  /// négociée avec le client.
  bool _dateTouched = false;
  // Date à laquelle la commande est effectivement passée. Default = now.
  // Antidatable sans limite passée (pour rattrapage de ventes hors-ligne /
  // saisie tardive / clôture comptable). PAS dans le futur (sinon ce
  // serait une commande programmée, capturée par _date).
  late DateTime _createdAt;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _addressCtrl;
  // Vente « à choisir sur place » : réserve le stock à la création puis
  // réconcilie à la clôture de la tournée (cf. reserveApprovalOrder).
  bool _isApprovalSale = false;
  String? _error;

  // ── Livraison par quartier (PR-2) ─────────────────────────────────────────
  List<String>           _cities    = [];
  List<DeliveryZone>     _zones     = [];
  List<DeliveryQuartier> _quartiers = []; // pour la ville courante
  String? _selectedQuartierId;
  double  _deliveryPrice = 0;
  String? _deliveryQuartierName;
  String? _deliveryZoneName;
  String? _zoneFilter;     // chip de zone sélectionné (filtre la liste)
  bool    _showManual = false;
  late final TextEditingController _manualNameCtrl;
  late final TextEditingController _manualPriceCtrl;

  @override
  void initState() {
    super.initState();
    _isApprovalSale = widget.initialIsApprovalSale;
    _client    = widget.initialClient;
    // `_createdAt` AVANT `_date` : le défaut de livraison en dépend.
    _createdAt = widget.initialCreatedAt ?? DateTime.now();
    // Commande neuve → livraison pré-remplie à +1 h. Édition (ou date déjà
    // posée dans le panier) → on reprend telle quelle et on la gèle.
    _dateTouched = widget.initialDate != null;
    _date        = widget.initialDate ?? _createdAt.add(_kDeliveryLead);
    _cityCtrl    = TextEditingController(
        text: widget.initialCity ?? widget.initialClient?.city ?? '');
    _addressCtrl = TextEditingController(
        text: widget.initialAddress ?? widget.initialClient?.district ?? '');
    _manualNameCtrl  = TextEditingController();
    _manualPriceCtrl = TextEditingController();
    // Livraison par quartier : charge le référentiel de la boutique.
    _cities = DeliveryZoneService.citiesForShop(widget.shopId);
    _zones  = DeliveryZoneService.zonesForShop(widget.shopId);
    _deliveryPrice        = widget.initialDeliveryPrice ?? 0;
    _deliveryQuartierName = widget.initialQuartier;
    _deliveryZoneName     = widget.initialZone;
    _reloadQuartiers();
  }

  @override
  void dispose() {
    _cityCtrl.dispose();
    _addressCtrl.dispose();
    _manualNameCtrl.dispose();
    _manualPriceCtrl.dispose();
    super.dispose();
  }

  /// Recharge les quartiers configurés pour la ville saisie + restaure la
  /// sélection si le quartier pré-rempli existe encore dans la liste.
  void _reloadQuartiers() {
    final city = _cityCtrl.text.trim();
    _quartiers = city.isEmpty
        ? <DeliveryQuartier>[]
        : DeliveryZoneService.quartiersForShop(widget.shopId, city: city);
    // Re-synchroniser la sélection avec le nom pré-rempli (édition).
    if (_selectedQuartierId == null && _deliveryQuartierName != null) {
      final match = _quartiers.where(
          (q) => q.name.toLowerCase() == _deliveryQuartierName!.toLowerCase());
      if (match.isNotEmpty) _selectedQuartierId = match.first.id;
    }
  }

  String? _zoneNameOf(String? zoneId) {
    if (zoneId == null) return null;
    final z = _zones.where((e) => e.id == zoneId);
    return z.isEmpty ? null : z.first.name;
  }

  void _selectQuartier(DeliveryQuartier q) {
    setState(() {
      _selectedQuartierId   = q.id;
      _deliveryPrice        = q.price.toDouble();
      _deliveryQuartierName = q.name;
      _deliveryZoneName     = _zoneNameOf(q.zoneId);
      _addressCtrl.text     = q.name; // l'adresse figée = le quartier
      _showManual = false;
      _error = null;
    });
  }

  Future<void> _addManualQuartier() async {
    final city  = _cityCtrl.text.trim();
    final name  = _manualNameCtrl.text.trim();
    final price = int.tryParse(_manualPriceCtrl.text.trim().replaceAll(' ', ''));
    if (city.isEmpty) {
      setState(() => _error = 'Renseigne d\'abord la ville.');
      return;
    }
    if (name.isEmpty || price == null || price < 0) {
      setState(() => _error = 'Nom du quartier + prix valides requis.');
      return;
    }
    final q = await DeliveryZoneService.addQuartier(
        shopId: widget.shopId, city: city, name: name, price: price);
    if (!mounted) return;
    setState(() {
      _quartiers =
          DeliveryZoneService.quartiersForShop(widget.shopId, city: city);
      _manualNameCtrl.clear();
      _manualPriceCtrl.clear();
    });
    _selectQuartier(q);
    if (mounted) AppSnack.success(context, 'Quartier ajouté à votre liste');
  }

  /// Calcule le montant déjà encaissé selon le choix utilisateur.
  /// Toujours `0` : une commande naît NON encaissée.
  ///
  /// L'encaissement est réservé à la clôture (statut Terminé) — cf. la
  /// section paiement retirée de ce sheet.
  double _resolveAmountPaid() => 0;

  Future<void> _pickClient() async {
    final picked = await showModalBottomSheet<Client>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _MiniClientPicker(shopId: widget.shopId),
    );
    if (picked != null && mounted) {
      setState(() {
        _client = picked;
        // Si l'utilisateur n'a pas explicitement saisi, pré-remplir avec
        // les coords du client fraîchement choisi.
        if (_cityCtrl.text.trim().isEmpty && (picked.city ?? '').isNotEmpty) {
          _cityCtrl.text = picked.city!;
        }
        if (_addressCtrl.text.trim().isEmpty
            && (picked.district ?? '').isNotEmpty) {
          _addressCtrl.text = picked.district!;
        }
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    // Repli aligné sur le défaut (+1 h après la commande) : le picker
    // s'ouvre là où le champ pointait, même après un effacement.
    final initial = _date ?? _createdAt.add(_kDeliveryLead);
    // Antidatable : firstDate = DateTime(2020) pour permettre de
    // numériser une livraison passée (commande déjà livrée avant
    // l'inscription Fortress). lastDate +365j pour garder la possibilité
    // de programmer une livraison future jusqu'à 1 an.
    final d = await showDatePicker(
      context:    context,
      initialDate: initial.isBefore(DateTime(2020))
          ? DateTime(2020)
          : initial,
      firstDate:  DateTime(2020),
      lastDate:   now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context:    context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (t == null || !mounted) return;
    setState(() {
      _date = DateTime(d.year, d.month, d.day, t.hour, t.minute);
      // Choix explicite : la livraison ne suit plus la date de commande.
      _dateTouched = true;
    });
  }

  /// Picker pour la date d'émission de la commande (antidatage possible).
  /// Bornes : firstDate très ancienne (pas de limite passé demandée par
  /// l'utilisateur), lastDate = maintenant (pas de futur ici — pour les
  /// commandes futures, utiliser `_pickDate` qui set `scheduledAt`).
  Future<void> _pickCreatedAt() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context:    context,
      initialDate: _createdAt,
      firstDate:  DateTime(2000),
      lastDate:   now,
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context:    context,
      initialTime: TimeOfDay.fromDateTime(_createdAt),
    );
    if (t == null || !mounted) return;
    var picked = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    // Garde-fou : si l'utilisateur sélectionne aujourd'hui + une heure
    // future, on clampe à maintenant (sinon la commande serait dans le
    // futur, ce qui contredit la sémantique createdAt).
    if (picked.isAfter(now)) picked = now;
    setState(() {
      _createdAt = picked;
      // Tant que l'heure de livraison n'a pas été fixée à la main, elle
      // reste collée à +1 h : antidater une commande d'hier place la
      // livraison à hier + 1 h, pas à demain.
      if (!_dateTouched) _date = picked.add(_kDeliveryLead);
    });
  }

  void _confirm() {
    // Tous les champs sont obligatoires pour qu'une commande soit
    // exploitable côté logistique : sans client → impossible de livrer ;
    // sans date → pas de planning ; sans ville/quartier → adresse vide.
    if (_client == null) {
      setState(() => _error = 'Sélectionne un client.');
      return;
    }
    if (_date == null) {
      setState(() => _error = 'Choisis la date et l\'heure de livraison.');
      return;
    }
    // FIX 2 — en retrait boutique (pickup), pas d'adresse de livraison :
    // ville/quartier ni exigés ni transmis (le bloc les nulle déjà pour pickup).
    final isPickup = widget.deliveryMode == DeliveryMode.pickup;
    final city    = _cityCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    if (!isPickup) {
      if (city.isEmpty) {
        setState(() => _error = 'Renseigne la ville de livraison.');
        return;
      }
      if (address.isEmpty) {
        setState(() => _error = 'Renseigne le quartier de livraison.');
        return;
      }
    }
    Navigator.of(context).pop(OrderCreationResult(
      client:          _client!,
      scheduledAt:     _date,
      deliveryCity:    isPickup ? null : city,
      deliveryAddress: isPickup ? null : address,
      createdAt:       _createdAt,
      amountPaid:      _resolveAmountPaid(),
      isApprovalSale:  _isApprovalSale,
      deliveryPrice:    isPickup ? 0 : _deliveryPrice,
      deliveryQuartier: isPickup ? null : _deliveryQuartierName,
      deliveryZone:     isPickup ? null : _deliveryZoneName,
    ));
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} à '
        '${two(d.hour)}:${two(d.minute)}';
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  void _onCityChanged() {
    setState(() {
      // Ville modifiée → la sélection quartier n'a plus de sens.
      _selectedQuartierId   = null;
      _deliveryPrice        = 0;
      _deliveryQuartierName = null;
      _deliveryZoneName     = null;
      _zoneFilter           = null;
      _showManual           = false;
      _error                = null;
      _reloadQuartiers();
    });
  }

  /// Section livraison « par quartier » : ville (étape A) → quartier avec
  /// prix (étape B) → ajout manuel (étape C) → récapitulatif.
  List<Widget> _buildDeliveryByQuartier(BuildContext context) {
    final sem  = Theme.of(context).semantic;
    final city = _cityCtrl.text.trim();
    final hasCity = city.isNotEmpty;
    // Zones présentes parmi les quartiers de la ville (pour les chips).
    final zoneIds = _quartiers
        .map((q) => q.zoneId)
        .whereType<String>()
        .toSet()
        .toList();
    final visibleQuartiers = _zoneFilter == null
        ? _quartiers
        : _quartiers.where((q) => q.zoneId == _zoneFilter).toList();

    return [
      // ── Étape A : Ville ────────────────────────────────────────────────
      TextField(
        controller: _cityCtrl,
        style: AppTextStyles.body.copyWith(color: AppColors.onSurface),
        onChanged: (_) => _onCityChanged(),
        decoration: InputDecoration(
          labelText: 'Ville',
          labelStyle:
              AppTextStyles.bodySm.copyWith(color: AppColors.textSecondary),
          hintText: 'Douala',
          hintStyle: AppTextStyles.bodySm.copyWith(color: AppColors.textHint),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: sem.borderSubtle)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: sem.borderSubtle)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
        ),
      ),
      // Villes configurées (remplissage rapide).
      if (_cities.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in _cities)
            ActionChip(
              label: Text(c, style: AppTextStyles.caption),
              onPressed: () {
                _cityCtrl.text = c;
                _onCityChanged();
              },
              backgroundColor: AppColors.primarySurface,
              side: BorderSide(color: AppColors.primary.withValues(alpha: 0.3)),
              visualDensity: VisualDensity.compact,
            ),
        ]),
      ],

      // ── Étape B : Quartier (visible seulement si ville saisie) ─────────
      if (hasCity) ...[
        const SizedBox(height: 14),
        const _SectionLabel('Quartier de livraison'),
        // Chips de zone (si des zones existent pour cette ville).
        if (zoneIds.length > 1) ...[
          Wrap(spacing: 6, runSpacing: 6, children: [
            ChoiceChip(
              label: const Text('Toutes'),
              selected: _zoneFilter == null,
              onSelected: (_) => setState(() => _zoneFilter = null),
              labelStyle: AppTextStyles.caption,
            ),
            for (final zid in zoneIds)
              ChoiceChip(
                label: Text(_zoneNameOf(zid) ?? 'Zone'),
                selected: _zoneFilter == zid,
                onSelected: (_) => setState(() => _zoneFilter = zid),
                labelStyle: AppTextStyles.caption,
              ),
          ]),
          const SizedBox(height: 8),
        ],
        if (_quartiers.isEmpty)
          // Aucun quartier configuré pour cette ville → saisie libre de
          // l'adresse (fallback) + possibilité d'ajouter un quartier.
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _LabeledField(
              label: 'Quartier / adresse',
              controller: _addressCtrl,
              hint: 'Bonapriso',
            ),
            const SizedBox(height: 4),
            Text(
              'Aucun tarif de livraison configuré pour « $city ». '
              'Saisissez l\'adresse, ou ajoutez un quartier tarifé ci-dessous.',
              style: AppTextStyles.captionHint
                  .copyWith(color: AppColors.textSecondary),
            ),
          ])
        else
          // Menu déroulant (compact) — évite une longue liste verticale.
          InputDecorator(
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              filled: true,
              fillColor: AppColors.inputFill,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: sem.borderSubtle)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: sem.borderSubtle)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: visibleQuartiers.any((q) => q.id == _selectedQuartierId)
                    ? _selectedQuartierId
                    : null,
                isExpanded: true,
                isDense: true,
                hint: Text('Choisir le quartier',
                    style:
                        AppTextStyles.body.copyWith(color: AppColors.textHint)),
                icon: const Icon(Icons.arrow_drop_down_rounded),
                style: AppTextStyles.body.copyWith(color: AppColors.onSurface),
                items: [
                  for (final q in visibleQuartiers)
                    DropdownMenuItem<String>(
                      value: q.id,
                      child: Row(children: [
                        Expanded(
                          child: Text(q.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.body
                                  .copyWith(color: AppColors.onSurface)),
                        ),
                        const SizedBox(width: 8),
                        Text(CurrencyFormatter.format(q.price.toDouble()),
                            style: AppTextStyles.bodyBold
                                .copyWith(color: AppColors.textSecondary)),
                      ]),
                    ),
                ],
                onChanged: (id) {
                  if (id == null) return;
                  final q = visibleQuartiers.firstWhere((e) => e.id == id);
                  _selectQuartier(q);
                },
              ),
            ),
          ),
        const SizedBox(height: 8),
        // ── Étape C : Quartier non listé ──────────────────────────────
        if (!_showManual)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showManual = true),
              icon: const Icon(Icons.add_location_alt_outlined, size: 16),
              label: const Text('Quartier non listé ?'),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  padding: EdgeInsets.zero),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.inputFill,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: Column(children: [
              _LabeledField(
                label: 'Nom du quartier',
                controller: _manualNameCtrl,
                hint: 'Ex. Logbessou',
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _manualPriceCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                style: AppTextStyles.body.copyWith(color: AppColors.onSurface),
                decoration: InputDecoration(
                  labelText: 'Prix livraison (FCFA)',
                  labelStyle: AppTextStyles.bodySm
                      .copyWith(color: AppColors.textSecondary),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: sem.borderSubtle)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: sem.borderSubtle)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide:
                          BorderSide(color: AppColors.primary, width: 1.5)),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => setState(() => _showManual = false),
                    child: const Text('Annuler'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _addManualQuartier,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        elevation: 0),
                    child: const Text('Ajouter et sélectionner'),
                  ),
                ),
              ]),
            ]),
          ),
      ],
      // Récapitulatif Produits / Livraison / Total retiré : le pied de page
      // affiche désormais le total et la part livraison (« dont livraison »).
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final isPickup = widget.deliveryMode == DeliveryMode.pickup;
    return AdaptiveFormFrame(
      title: 'Enregistrer la commande',
      icon:  Icons.shopping_bag_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 1. Client ────────────────────────────────────────────────
            const _SectionLabel('Client'),
            _FormCard(children: [
              _IconRow(
                icon:      Icons.person_outline_rounded,
                iconColor: sem.warning,
                iconBg:    sem.warningSurface,
                title:     _client?.name ?? 'Choisir / créer un client',
                subtitle:  _client?.phone,
                onTap:     _pickClient,
              ),
            ]),
            const SizedBox(height: AppSpacing.lg),

            // ── 2. Planification ─────────────────────────────────────────
            const _SectionLabel('Planification'),
            _FormCard(children: [
              _IconRow(
                icon:      Icons.calendar_today_outlined,
                iconColor: sem.info,
                iconBg:    sem.info.withValues(alpha: 0.12),
                title:     _fmtDate(_createdAt),
                subtitle:  _isToday(_createdAt)
                    ? 'Date de commande · aujourd\'hui (par défaut)'
                    : 'Date de commande · antidatée',
                onTap:     _pickCreatedAt,
              ),
              _IconRow(
                icon:      Icons.local_shipping_outlined,
                iconColor: sem.success,
                iconBg:    sem.successSurface,
                title:     _date == null
                    ? 'Choisir la date et l\'heure'
                    : _fmtDate(_date!),
                subtitle:  _date != null && !_dateTouched
                    ? 'Date de livraison souhaitée · 1 h après'
                    : 'Date de livraison souhaitée',
                onTap:     _pickDate,
                trailing: _date == null
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close_rounded,
                            size: 16, color: AppColors.textSecondary),
                        tooltip: 'Effacer la date de livraison',
                        // Effacer est aussi un choix explicite : sans ça,
                        // modifier la date de commande reremplirait le
                        // champ que l'utilisateur vient de vider.
                        onPressed: () => setState(() {
                          _date        = null;
                          _dateTouched = true;
                        }),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 28, minHeight: 28),
                      ),
              ),
            ]),

            // Retrait en boutique → aucune section « Lieu de livraison »
            // (pavé « aucune adresse requise » redondant, supprimé). La
            // section n'apparaît que pour une vraie livraison, avec le
            // choix du quartier (→ frais de livraison).
            if (!isPickup) ...[
              const SizedBox(height: AppSpacing.lg),
              const _SectionLabel('Lieu de livraison'),
              ..._buildDeliveryByQuartier(context),
            ],

            // ── 3. Mode de livraison : vente « à choisir sur place » ─────
            // Le livreur emporte plusieurs articles, le client en garde
            // certains, le reste revient. Le stock est réservé à la
            // création puis réconcilié à la clôture de la tournée.
            const SizedBox(height: AppSpacing.lg),
            const _SectionLabel('Mode de livraison'),
            _ApprovalSaleToggle(
              value: _isApprovalSale,
              enabled: !widget.lockApproval,
              onChanged: (v) => setState(() => _isApprovalSale = v),
            ),
          ],
        ),
      ),
      footer: _buildFooter(context, isPickup: isPickup),
    );
  }

  /// Pied de page épinglé : total, mode de paiement, erreur de validation
  /// (toujours visible, même formulaire défilé) et actions.
  Widget _buildFooter(BuildContext context, {required bool isPickup}) {
    final sem = Theme.of(context).semantic;
    // Total facturé au client = articles + livraison choisie. Livraison non
    // facturée en retrait boutique (cf. `_confirm`) : le total affiché
    // reflète exactement ce qui sera enregistré.
    final deliveryPrice = isPickup ? 0.0 : _deliveryPrice;
    final total         = (widget.orderTotal ?? 0) + deliveryPrice;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Aucun encaissement à la création (règle métier) ──────────
          // Rien ne rentre en caisse tant que la commande n'est pas
          // TERMINÉE : le montant se saisit à la clôture, quand la
          // marchandise est réellement remise. Un acompte pris ici
          // survivait à une annulation et laissait un remboursement
          // à traiter à la main, hors de tout suivi.
          if ((widget.orderTotal ?? 0) > 0) ...[
            Row(children: [
              Expanded(
                child: Text('Total',
                    style: AppTextStyles.bodySm
                        .copyWith(color: AppColors.textSecondary)),
              ),
              Text(_fmtMoney(total),
                  style: AppTextStyles.title.copyWith(
                      fontWeight: FontWeight.w500,
                      color: AppColors.primary)),
            ]),
            if (deliveryPrice > 0)
              Align(
                alignment: Alignment.centerRight,
                child: Text('dont livraison — ${_fmtMoney(deliveryPrice)}',
                    style: AppTextStyles.captionHint),
              ),
            const SizedBox(height: AppSpacing.xs),
            Row(children: [
              Expanded(
                child: Text('Paiement', style: AppTextStyles.captionHint),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: 3),
                decoration: BoxDecoration(
                  color: sem.info.withValues(alpha: 0.12),
                  borderRadius:
                      const BorderRadius.all(Radius.circular(AppRadius.xs)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.schedule_rounded, size: 13, color: sem.info),
                  const SizedBox(width: AppSpacing.xs),
                  Text('À la clôture',
                      style: AppTextStyles.caption.copyWith(
                          fontWeight: FontWeight.w500, color: sem.info)),
                ]),
              ),
            ]),
            const SizedBox(height: AppSpacing.md),
          ],
          if (_error != null) ...[
            Text(_error!,
                style: AppTextStyles.captionHint.copyWith(color: sem.danger)),
            const SizedBox(height: AppSpacing.sm),
          ],
          ElevatedButton.icon(
            onPressed: _confirm,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Enregistrer la commande'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              minimumSize: const Size.fromHeight(48),
              shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdR),
            ),
          ),
          // Annuler gardé (certains appareils n'ont pas de geste retour
          // évident) mais en retrait visuel : simple bouton texte.
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              minimumSize: const Size.fromHeight(40),
            ),
            child: const Text('Annuler'),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers UI privés ─────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label.toUpperCase(),
            style: AppTextStyles.caption.copyWith(
                letterSpacing: 0.5, color: AppColors.textHint)),
      );
}

/// Carte groupant une ou plusieurs lignes, séparées par un filet de 0,5 px.
class _FormCard extends StatelessWidget {
  final List<Widget> children;
  const _FormCard({required this.children});
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Material(
      color: AppColors.inputFill,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.mdR,
        side: BorderSide(color: sem.borderSubtle, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            Divider(height: 0.5, thickness: 0.5, color: sem.borderSubtle),
          children[i],
        ],
      ]),
    );
  }
}

/// Pastille 32×32 teintée portant l'icône d'une ligne (couleur par type).
class _IconBadge extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color background;
  const _IconBadge({
    required this.icon, required this.color, required this.background,
  });
  @override
  Widget build(BuildContext context) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 32, height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
        ),
        child: Icon(icon, size: 18, color: color),
      );
}

/// Ligne cliquable : pastille d'icône + titre/sous-titre + chevron (ou
/// `trailing` personnalisé, ex. croix d'effacement).
class _IconRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  const _IconRow({
    required this.icon, required this.iconColor, required this.iconBg,
    required this.title, this.subtitle, required this.onTap, this.trailing,
  });
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: 10),
        child: Row(children: [
          _IconBadge(icon: icon, color: iconColor, background: iconBg),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(title,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w500, color: AppColors.onSurface)),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(subtitle!,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.captionHint),
          ])),
          if (trailing != null) trailing!
          else Icon(Icons.chevron_right_rounded,
              size: 18, color: AppColors.textHint),
        ]),
      ),
    );
  }
}

/// Bascule « À choisir sur place » : active la réservation de stock pour une
/// tournée d'approbation (le livreur emporte plusieurs articles, le client en
/// garde certains, le reste revient et est remis en stock à la clôture).
///
/// Carte réactive : neutre quand désactivée, ambre + badge explicatif quand
/// activée (transition animée 200 ms).
class _ApprovalSaleToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  /// Quand false (édition d'une commande existante), le switch est verrouillé :
  /// il reflète l'état mais n'est pas modifiable (la réservation est déjà faite).
  final bool enabled;
  const _ApprovalSaleToggle({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  static const _kAnim = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Opacity(
      opacity: enabled ? 1 : 0.65,
      child: AnimatedContainer(
        duration: _kAnim,
        decoration: BoxDecoration(
          color: value ? sem.warningSurface : AppColors.inputFill,
          borderRadius: AppRadius.mdR,
          border: Border.all(
              color: value ? sem.warning : sem.borderSubtle,
              width: value ? 1 : 0.5),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: enabled ? () => onChanged(!value) : null,
            borderRadius: AppRadius.mdR,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    _IconBadge(
                      icon: Icons.inventory_2_outlined,
                      color: value ? sem.warningText : AppColors.textSecondary,
                      background: value
                          ? sem.warning.withValues(alpha: 0.3)
                          : AppColors.surface,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(children: [
                            Flexible(
                              child: Text('À choisir sur place',
                                  style: AppTextStyles.body.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.onSurface)),
                            ),
                            if (!enabled) ...[
                              const SizedBox(width: 6),
                              Icon(Icons.lock_outline_rounded,
                                  size: 13, color: AppColors.textSecondary),
                            ],
                          ]),
                          Text(
                            enabled
                                ? 'Stock réservé · Clôture à la livraison'
                                : 'Mode défini à la création — '
                                  'non modifiable ici.',
                            style: AppTextStyles.captionHint,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    AppSwitch(
                      value: value,
                      activeColor: sem.warning,
                      onChanged: enabled ? onChanged : null,
                    ),
                  ]),
                  AnimatedSize(
                    duration: _kAnim,
                    alignment: Alignment.topCenter,
                    child: !value
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.sm),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.sm,
                                  vertical: AppSpacing.xs),
                              decoration: BoxDecoration(
                                color: sem.warning.withValues(alpha: 0.25),
                                borderRadius: const BorderRadius.all(
                                    Radius.circular(AppRadius.xs)),
                              ),
                              child: Row(children: [
                                Icon(Icons.info_outline_rounded,
                                    size: 14, color: sem.warningText),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Le stock est réservé puis réconcilié '
                                    'à la clôture',
                                    style: AppTextStyles.caption
                                        .copyWith(color: sem.warningText),
                                  ),
                                ),
                              ]),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  const _LabeledField({
    required this.label, required this.hint, required this.controller,
  });
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: AppTextStyles.body.copyWith(color: AppColors.onSurface),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTextStyles.bodySm
            .copyWith(color: AppColors.textSecondary),
        hintText: hint,
        hintStyle: AppTextStyles.bodySm
            .copyWith(color: AppColors.textHint),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide:
                BorderSide(color: Theme.of(context).semantic.borderSubtle)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide:
                BorderSide(color: Theme.of(context).semantic.borderSubtle)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      ),
    );
  }
}


// ─── Mini picker client (recherche + bouton créer) ─────────────────────────

class _MiniClientPicker extends StatefulWidget {
  final String shopId;
  const _MiniClientPicker({required this.shopId});
  @override
  State<_MiniClientPicker> createState() => _MiniClientPickerState();
}

class _MiniClientPickerState extends State<_MiniClientPicker> {
  String _query = '';
  List<Client> _clients = [];

  @override
  void initState() {
    super.initState();
    _clients = AppDatabase.getClientsForShop(widget.shopId);
  }

  List<Client> get _filtered => _query.isEmpty
      ? _clients
      : _clients.where((c) =>
          c.name.toLowerCase().contains(_query.toLowerCase()) ||
          (c.phone?.contains(_query) ?? false)).toList();

  Future<void> _createNew() async {
    final picker = Navigator.of(context); // capture avant push
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (formCtx) => ClientFormSheet(
        shopId: widget.shopId,
        onSaved: () {
          // ClientFormSheet a déjà sauvegardé via AppDatabase.saveClient.
          // Récupère le dernier client créé pour le retourner au picker.
          Navigator.of(formCtx).pop();
          final all = AppDatabase.getClientsForShop(widget.shopId);
          if (all.isEmpty) return;
          final newest = all.reduce((a, b) =>
              a.createdAt.isAfter(b.createdAt) ? a : b);
          picker.pop(newest);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize:     0.4,
      maxChildSize:     0.95,
      expand: false,
      builder: (_, sc) => Column(children: [
        // Poignée
        Container(margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2))),
        // Titre
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(alignment: Alignment.centerLeft,
            child: Text('Sélectionner un client',
                style: AppTextStyles.subtitleBold),
          ),
        ),
        // Recherche + bouton + sur la MÊME LIGNE
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Row(children: [
            Expanded(child: TextField(
              onChanged: (v) => setState(() => _query = v),
              // Ouvre le clavier directement → −1 tap à chaque vente.
              autofocus: true,
              // Clavier texte (et non `phone`) : la recherche se fait par
              // numéro OU par nom — un clavier numérique empêchait de taper
              // le nom du client sur mobile.
              keyboardType: TextInputType.text,
              style: AppTextStyles.body,
              decoration: InputDecoration(
                hintText: 'Rechercher par numéro ou nom…',
                hintStyle: AppTextStyles.bodySm
                    .copyWith(color: AppColors.textHint),
                prefixIcon: Icon(Icons.search_rounded,
                    size: 16, color: AppColors.textHint),
                filled: true, fillColor: AppColors.inputFill,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: sem.borderSubtle)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: sem.borderSubtle)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.primary, width: 1.5)),
              ),
            )),
            const SizedBox(width: 8),
            // Icône + pour créer un nouveau client (même ligne que la
            // recherche, comme demandé spec).
            Material(
              color: sem.brand,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _createNew,
                child: Container(
                  width: 40, height: 40,
                  alignment: Alignment.center,
                  child: const Icon(Icons.add_rounded,
                      size: 22, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),
        Divider(height: 1, color: sem.borderSubtle),
        // Liste clients (scroll vertical sur cette zone uniquement)
        Expanded(
          child: _filtered.isEmpty
              ? Center(child: Text('Aucun client',
                  style: AppTextStyles.bodySm
                      .copyWith(color: AppColors.textHint)))
              : ListView.separated(
                  controller: sc,
                  itemCount: _filtered.length,
                  separatorBuilder: (_, __) => Divider(
                      height: 1, color: sem.borderSubtle),
                  itemBuilder: (_, i) {
                    final c = _filtered[i];
                    return ListTile(
                      onTap: () => Navigator.of(context).pop(c),
                      title: Text(c.name,
                          style: AppTextStyles.bodyBold),
                      subtitle: Text(
                          [c.phone, c.city, c.district]
                              .whereType<String>()
                              .where((s) => s.isNotEmpty)
                              .join(' · '),
                          style: AppTextStyles.captionHint
                              .copyWith(color: AppColors.textSecondary)),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}



String _fmtMoney(double amount) {
  final fmt = NumberFormat('#,###', 'fr_FR');
  return '${fmt.format(amount)} ${CurrencyFormatter.currentSymbol}';
}
