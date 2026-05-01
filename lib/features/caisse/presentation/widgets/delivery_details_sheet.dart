import 'package:flutter/material.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/autocomplete_text_field.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../data/repositories/sale_local_datasource.dart';
import '../../domain/entities/sale.dart';

// ═════════════════════════════════════════════════════════════════════════════
// DeliveryDetailsSheet — bottom-sheet unique invoqué quand une commande passe
// au statut `completed` (depuis le panier au moment de l'encaissement, ou
// depuis la liste des commandes lors d'un changement de statut manuel).
//
// Couvre :
//   • Mode (pickup / inHouse / partner / shipment)
//   • Livreur (inHouse / partner)
//   • Partenaire (dropdown — mode partner)
//   • Ville + adresse de livraison (inHouse / partner / shipment)
//   • Ville d'origine + agence + responsable d'expédition (mode shipment)
//   • Date + heure de livraison
//
// Les valeurs ville / agence / responsable sont auto-complétées à partir des
// commandes déjà saisies dans la boutique (réutilisation des libellés sans
// table de référence).
//
// Le sheet est purement présentationnel : il NE TOUCHE PAS au CaisseBloc.
// Au "Confirmer" il `pop()` avec un [DeliveryDetailsResult] que l'appelant
// applique à sa convenance (mise à jour d'une commande existante ou
// `SetDeliveryDetails` puis `CompleteSale`).
// ═════════════════════════════════════════════════════════════════════════════

class DeliveryDetailsResult {
  final PaymentMethod paymentMethod;
  final DeliveryMode mode;
  final String? locationId;
  final String? personName;
  final String? deliveryCity;
  final String? deliveryAddress;
  final String? shipmentCity;
  final String? shipmentAgency;
  final String? shipmentHandler;
  final DateTime? date;
  const DeliveryDetailsResult({
    required this.paymentMethod,
    required this.mode,
    this.locationId,
    this.personName,
    this.deliveryCity,
    this.deliveryAddress,
    this.shipmentCity,
    this.shipmentAgency,
    this.shipmentHandler,
    this.date,
  });
}

Future<DeliveryDetailsResult?> showDeliveryDetailsSheet(
  BuildContext context, {
  required String shopId,
  PaymentMethod? initialPaymentMethod,
  DeliveryMode? initialMode,
  String? initialLocationId,
  String? initialPersonName,
  String? initialDeliveryCity,
  String? initialDeliveryAddress,
  String? initialShipmentCity,
  String? initialShipmentAgency,
  String? initialShipmentHandler,
  DateTime? initialDate,
}) {
  return showModalBottomSheet<DeliveryDetailsResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _DeliveryDetailsSheet(
      shopId:                 shopId,
      initialPaymentMethod:   initialPaymentMethod,
      initialMode:            initialMode,
      initialLocationId:      initialLocationId,
      initialPersonName:      initialPersonName,
      initialDeliveryCity:    initialDeliveryCity,
      initialDeliveryAddress: initialDeliveryAddress,
      initialShipmentCity:    initialShipmentCity,
      initialShipmentAgency:  initialShipmentAgency,
      initialShipmentHandler: initialShipmentHandler,
      initialDate:            initialDate,
    ),
  );
}

class _DeliveryDetailsSheet extends StatefulWidget {
  final String shopId;
  final PaymentMethod? initialPaymentMethod;
  final DeliveryMode? initialMode;
  final String? initialLocationId;
  final String? initialPersonName;
  final String? initialDeliveryCity;
  final String? initialDeliveryAddress;
  final String? initialShipmentCity;
  final String? initialShipmentAgency;
  final String? initialShipmentHandler;
  final DateTime? initialDate;
  const _DeliveryDetailsSheet({
    required this.shopId,
    this.initialPaymentMethod,
    this.initialMode,
    this.initialLocationId,
    this.initialPersonName,
    this.initialDeliveryCity,
    this.initialDeliveryAddress,
    this.initialShipmentCity,
    this.initialShipmentAgency,
    this.initialShipmentHandler,
    this.initialDate,
  });

  @override
  State<_DeliveryDetailsSheet> createState() => _DeliveryDetailsSheetState();
}

class _DeliveryDetailsSheetState extends State<_DeliveryDetailsSheet> {
  late PaymentMethod _payment;
  late DeliveryMode _mode;
  String? _locationId;

  late final TextEditingController _personCtrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _shipCityCtrl;
  late final TextEditingController _shipAgencyCtrl;
  late final TextEditingController _shipHandlerCtrl;
  DateTime? _date;

  List<StockLocation> _partners = [];
  List<String> _cities = [];
  List<String> _shipCities = [];
  List<String> _agencies = [];
  List<String> _handlers = [];
  List<String> _persons = [];

  @override
  void initState() {
    super.initState();
    _payment = widget.initialPaymentMethod ?? PaymentMethod.cash;
    _mode = widget.initialMode ?? DeliveryMode.pickup;
    _locationId = widget.initialLocationId;
    _personCtrl     = TextEditingController(text: widget.initialPersonName ?? '');
    _cityCtrl       = TextEditingController(text: widget.initialDeliveryCity ?? '');
    _addressCtrl    = TextEditingController(text: widget.initialDeliveryAddress ?? '');
    _shipCityCtrl   = TextEditingController(text: widget.initialShipmentCity ?? '');
    _shipAgencyCtrl = TextEditingController(text: widget.initialShipmentAgency ?? '');
    _shipHandlerCtrl= TextEditingController(text: widget.initialShipmentHandler ?? '');
    _date = widget.initialDate;

    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    _partners = AppDatabase.getStockLocationsForOwner(userId)
        .where((l) => l.type == StockLocationType.partner && l.isActive)
        .toList();

    _loadAutocompleteSuggestions();

    if (_mode == DeliveryMode.partner
        && _locationId == null
        && _partners.isNotEmpty) {
      _locationId = _partners.first.id;
    }
  }

  void _loadAutocompleteSuggestions() {
    final orders = SaleLocalDatasource().getOrders(widget.shopId);
    final cities = <String>{};
    final shipCities = <String>{};
    final agencies = <String>{};
    final handlers = <String>{};
    final persons = <String>{};
    for (final o in orders) {
      final c = o.deliveryCity?.trim();
      if (c != null && c.isNotEmpty) cities.add(c);
      final sc = o.shipmentCity?.trim();
      if (sc != null && sc.isNotEmpty) shipCities.add(sc);
      final a = o.shipmentAgency?.trim();
      if (a != null && a.isNotEmpty) agencies.add(a);
      final h = o.shipmentHandler?.trim();
      if (h != null && h.isNotEmpty) handlers.add(h);
      final p = o.deliveryPersonName?.trim();
      if (p != null && p.isNotEmpty) persons.add(p);
    }
    _cities     = cities.toList()..sort();
    _shipCities = shipCities.toList()..sort();
    _agencies   = agencies.toList()..sort();
    _handlers   = handlers.toList()..sort();
    _persons    = persons.toList()..sort();
  }

  @override
  void dispose() {
    _personCtrl.dispose();
    _cityCtrl.dispose();
    _addressCtrl.dispose();
    _shipCityCtrl.dispose();
    _shipAgencyCtrl.dispose();
    _shipHandlerCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      locale: const Locale('fr', 'FR'),
    );
    if (picked == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(
          _date ?? DateTime(picked.year, picked.month, picked.day, 14)),
    );
    if (!mounted) return;
    setState(() => _date = DateTime(
        picked.year, picked.month, picked.day,
        time?.hour ?? 14, time?.minute ?? 0));
  }

  String _formatDate(DateTime d) {
    const days = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin',
                    'juil', 'août', 'sep', 'oct', 'nov', 'déc'];
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} · $h:$m';
  }

  String? _validate() {
    if (_mode == DeliveryMode.partner) {
      if (_locationId == null || _locationId!.isEmpty) {
        return 'Choisissez le partenaire de livraison.';
      }
      if (_cityCtrl.text.trim().isEmpty) {
        return 'Renseignez la ville de livraison.';
      }
    }
    if (_mode == DeliveryMode.inHouse) {
      if (_cityCtrl.text.trim().isEmpty) {
        return 'Renseignez la ville de livraison.';
      }
    }
    if (_mode == DeliveryMode.shipment) {
      if (_cityCtrl.text.trim().isEmpty) {
        return 'Renseignez la ville de livraison du destinataire.';
      }
      if (_shipAgencyCtrl.text.trim().isEmpty) {
        return 'Renseignez le nom de l\'agence d\'expédition.';
      }
      if (_shipHandlerCtrl.text.trim().isEmpty) {
        return 'Renseignez le responsable de l\'expédition.';
      }
    }
    return null;
  }

  void _confirm() {
    final err = _validate();
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    String? trimmed(TextEditingController c) {
      final v = c.text.trim();
      return v.isEmpty ? null : v;
    }
    final isShipment = _mode == DeliveryMode.shipment;
    final isPartner  = _mode == DeliveryMode.partner;
    final isInHouse  = _mode == DeliveryMode.inHouse;
    final isPickup   = _mode == DeliveryMode.pickup;
    Navigator.of(context).pop(DeliveryDetailsResult(
      paymentMethod:   _payment,
      mode:            _mode,
      locationId:      isPartner ? _locationId : null,
      personName:      (isInHouse || isPartner) ? trimmed(_personCtrl) : null,
      deliveryCity:    isPickup ? null : trimmed(_cityCtrl),
      deliveryAddress: isPickup ? null : trimmed(_addressCtrl),
      shipmentCity:    isShipment ? trimmed(_shipCityCtrl)   : null,
      shipmentAgency:  isShipment ? trimmed(_shipAgencyCtrl) : null,
      shipmentHandler: isShipment ? trimmed(_shipHandlerCtrl): null,
      date:            isPickup ? null : _date,
    ));
  }

  /// Annule sans rien retourner — l'appelant ne touche à rien.
  void _cancel() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final maxH = MediaQuery.of(context).size.height * 0.92;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: maxH,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: [
              _header(),
              const Divider(height: 1, color: AppColors.divider),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _section('Mode de paiement'),
                      const SizedBox(height: 8),
                      _paymentTiles(),
                      const SizedBox(height: 14),
                      _section('Mode de livraison'),
                      const SizedBox(height: 8),
                      _modeTiles(),
                      if (_mode == DeliveryMode.inHouse) ...[
                        const SizedBox(height: 14),
                        _section('Livreur (interne)'),
                        const SizedBox(height: 8),
                        _personField(),
                        const SizedBox(height: 14),
                        _section('Adresse de livraison'),
                        const SizedBox(height: 8),
                        _cityField(),
                        const SizedBox(height: 10),
                        _addressField(),
                      ],
                      if (_mode == DeliveryMode.partner) ...[
                        const SizedBox(height: 14),
                        _section('Partenaire'),
                        const SizedBox(height: 8),
                        _partnerDropdown(),
                        const SizedBox(height: 10),
                        _personField(hint: 'Contact chez le partenaire (optionnel)'),
                        const SizedBox(height: 14),
                        _section('Adresse de livraison'),
                        const SizedBox(height: 8),
                        _cityField(),
                        const SizedBox(height: 10),
                        _addressField(),
                      ],
                      if (_mode == DeliveryMode.shipment) ...[
                        const SizedBox(height: 14),
                        _section('Expédition'),
                        const SizedBox(height: 8),
                        _shipCityField(),
                        const SizedBox(height: 10),
                        _agencyField(),
                        const SizedBox(height: 10),
                        _handlerField(),
                        const SizedBox(height: 14),
                        _section('Adresse de livraison du destinataire'),
                        const SizedBox(height: 8),
                        _cityField(),
                        const SizedBox(height: 10),
                        _addressField(),
                      ],
                      if (_mode != DeliveryMode.pickup) ...[
                        const SizedBox(height: 14),
                        _section('Date de livraison réelle'),
                        const SizedBox(height: 8),
                        _dateField(),
                      ],
                      if (_mode == DeliveryMode.pickup) ...[
                        const SizedBox(height: 14),
                        _pickupNotice(),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: AppColors.divider),
              _bottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
    child: Column(
      children: [
        Center(
          child: Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: AppColors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.local_shipping_rounded,
                size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Détails de livraison',
                style: TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary)),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            color: AppColors.textHint,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ]),
      ],
    ),
  );

  Widget _section(String label) => Text(
    label.toUpperCase(),
    style: TextStyle(fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        color: AppColors.textSecondary),
  );

  Widget _paymentTiles() {
    const methods = [
      (PaymentMethod.cash,        Icons.payments_rounded,
          'Espèces',        Color(0xFF10B981)),
      (PaymentMethod.mobileMoney, Icons.phone_android_rounded,
          'Mobile Money',   Color(0xFFF97316)),
      (PaymentMethod.card,        Icons.credit_card_rounded,
          'Carte bancaire', Color(0xFF3B82F6)),
      (PaymentMethod.credit,      Icons.handshake_rounded,
          'Crédit',         Color(0xFFB45309)),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in methods) Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ModeTile(
            icon: m.$2,
            label: m.$3,
            subtitle: '',
            color: m.$4,
            selected: _payment == m.$1,
            onTap: () => setState(() => _payment = m.$1),
          ),
        ),
      ],
    );
  }

  Widget _modeTiles() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _ModeTile(
        icon: Icons.store_rounded,
        label: 'Retrait en boutique',
        subtitle: 'Le client vient récupérer',
        color: AppColors.primary,
        selected: _mode == DeliveryMode.pickup,
        onTap: () => setState(() {
          _mode = DeliveryMode.pickup;
          _locationId = null;
        }),
      ),
      const SizedBox(height: 8),
      _ModeTile(
        icon: Icons.delivery_dining_rounded,
        label: 'Livraison par notre équipe',
        subtitle: 'Un membre ou coursier livre',
        color: AppColors.secondary,
        selected: _mode == DeliveryMode.inHouse,
        onTap: () => setState(() {
          _mode = DeliveryMode.inHouse;
          _locationId = null;
        }),
      ),
      const SizedBox(height: 8),
      _ModeTile(
        icon: Icons.local_shipping_rounded,
        label: 'Livraison partenaire',
        subtitle: _partners.isEmpty
            ? 'Aucun partenaire — Paramètres → Emplacements'
            : 'Un dépôt partenaire livre depuis son stock',
        color: _partners.isEmpty ? AppColors.textHint : AppColors.warning,
        selected: _mode == DeliveryMode.partner,
        onTap: _partners.isEmpty ? null : () => setState(() {
          _mode = DeliveryMode.partner;
          _locationId ??= _partners.first.id;
        }),
      ),
      const SizedBox(height: 8),
      _ModeTile(
        icon: Icons.flight_takeoff_rounded,
        label: 'Expédition par agence',
        subtitle: 'DHL, Express Union, La Poste…',
        color: const Color(0xFF6C3FC7),
        selected: _mode == DeliveryMode.shipment,
        onTap: () => setState(() {
          _mode = DeliveryMode.shipment;
          _locationId = null;
        }),
      ),
    ],
  );

  Widget _partnerDropdown() => DropdownButtonFormField<String>(
    value: _locationId,
    items: _partners.map((p) => DropdownMenuItem<String>(
      value: p.id,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.local_shipping_rounded,
            size: 14, color: AppColors.warning),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(p.name,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
        ),
      ]),
    )).toList(),
    onChanged: (id) => setState(() => _locationId = id),
    isDense: true, isExpanded: true,
    decoration: _decoration(hint: 'Sélectionner un partenaire'),
  );

  Widget _personField({String? hint}) => TextField(
    controller: _personCtrl,
    style: const TextStyle(fontSize: 13),
    decoration: _decoration(
      hint: hint ?? 'Nom du livreur (optionnel)',
      icon: Icons.person_outline,
    ),
  );

  Widget _cityField() => AutocompleteTextField(
    controller: _cityCtrl,
    label: 'Ville de livraison',
    hint: 'Ex: Yaoundé, Douala…',
    suggestions: _cities,
    prefixIcon: Icons.location_city_rounded,
    required: _mode != DeliveryMode.pickup,
  );

  Widget _addressField() => TextField(
    controller: _addressCtrl,
    style: const TextStyle(fontSize: 13),
    maxLines: 2,
    minLines: 1,
    textCapitalization: TextCapitalization.sentences,
    decoration: _decoration(
      hint: 'Adresse précise (rue, quartier, immeuble) — optionnel',
      icon: Icons.place_outlined,
    ),
  );

  Widget _shipCityField() => AutocompleteTextField(
    controller: _shipCityCtrl,
    label: 'Ville d\'origine de l\'expédition',
    hint: 'Où l\'agence prend le colis',
    suggestions: _shipCities,
    prefixIcon: Icons.outbox_rounded,
  );

  Widget _agencyField() => AutocompleteTextField(
    controller: _shipAgencyCtrl,
    label: 'Agence d\'expédition',
    hint: 'Ex: DHL, Express Union…',
    suggestions: _agencies,
    prefixIcon: Icons.business_rounded,
    required: true,
  );

  Widget _handlerField() => AutocompleteTextField(
    controller: _shipHandlerCtrl,
    label: 'Responsable de l\'envoi',
    hint: 'Qui a déposé le colis à l\'agence',
    suggestions: [..._handlers, ..._persons].toSet().toList()..sort(),
    prefixIcon: Icons.badge_outlined,
    required: true,
  );

  Widget _dateField() {
    final has = _date != null;
    return InkWell(
      onTap: _pickDate,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: has
              ? AppColors.primary.withOpacity(0.06)
              : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: has
                ? AppColors.primary.withOpacity(0.30)
                : AppColors.divider,
          ),
        ),
        child: Row(children: [
          Icon(Icons.event_rounded,
              size: 16,
              color: has ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 8),
          Expanded(child: Text(
              has
                  ? _formatDate(_date!)
                  : 'Quand a-t-elle été livrée ? (optionnel)',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: has ? FontWeight.w600 : FontWeight.w400,
                  color: has
                      ? AppColors.primary
                      : AppColors.textSecondary))),
          if (has)
            InkWell(
              onTap: () => setState(() => _date = null),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close_rounded,
                    size: 14, color: AppColors.textHint),
              ),
            )
          else
            const Icon(Icons.chevron_right_rounded,
                size: 16, color: AppColors.textHint),
        ]),
      ),
    );
  }

  Widget _pickupNotice() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.primary.withOpacity(0.06),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: AppColors.primary.withOpacity(0.20)),
    ),
    child: Row(children: [
      Icon(Icons.info_outline_rounded,
          size: 16, color: AppColors.primary),
      const SizedBox(width: 8),
      const Expanded(
        child: Text(
          'Aucune adresse ni date à renseigner — le client passe en boutique.',
          style: TextStyle(fontSize: 12, color: AppColors.textPrimary),
        ),
      ),
    ]),
  );

  Widget _bottomBar() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
    // Pattern aligné sur `transfer_form_sheet.dart` : `Expanded` distribue
    // les largeurs aux boutons → pas de `Spacer` ni de `SizedBox` sans
    // largeur, qui provoquaient un crash "BoxConstraints forces an infinite
    // width" / "RenderBox was not laid out".
    child: Row(children: [
      Expanded(
        child: TextButton(
          style: TextButton.styleFrom(
            foregroundColor: AppColors.textSecondary,
            minimumSize: const Size(0, 44),
          ),
          onPressed: _cancel,
          child: const Text('Annuler'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        flex: 2,
        child: ElevatedButton.icon(
          onPressed: _confirm,
          icon: const Icon(Icons.check_rounded, size: 16),
          label: const Text('Confirmer'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 18),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ),
    ]),
  );

  InputDecoration _decoration({String? hint, IconData? icon}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
        prefixIcon: icon != null
            ? Icon(icon, size: 15, color: const Color(0xFFAAAAAA))
            : null,
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      );
}

// ─── Tuile mode ──────────────────────────────────────────────────────────────
class _ModeTile extends StatelessWidget {
  final IconData icon;
  final String label, subtitle;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  const _ModeTile({
    required this.icon, required this.label, required this.subtitle,
    required this.color, required this.selected, this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: selected ? color.withOpacity(0.08) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? color : const Color(0xFFE5E7EB),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: onTap == null
                          ? AppColors.textHint
                          : (selected ? color : const Color(0xFF0F172A)))),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(fontSize: 11,
                        color: Color(0xFF9CA3AF))),
              ],
            ],
          ),
        ),
        Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_off_rounded,
            size: 16,
            color: selected ? color : const Color(0xFFBBBBBB)),
      ]),
    ),
  );
}
