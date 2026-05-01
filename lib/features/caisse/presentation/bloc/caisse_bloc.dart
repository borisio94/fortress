import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../domain/entities/sale.dart';
import '../../domain/entities/sale_item.dart';
import '../../../crm/domain/entities/client.dart';
import '../../data/repositories/sale_local_datasource.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../inventaire/domain/entities/product.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../core/services/delivery_reminder_service.dart';

// ─── Frais de commande (livraison, expédition…) ───────────────────────────────
class OrderFee {
  final String id;
  final String label;
  final double amount;
  const OrderFee({required this.id, required this.label, required this.amount});
  OrderFee copyWith({String? label, double? amount}) =>
      OrderFee(id: id, label: label ?? this.label, amount: amount ?? this.amount);
}

// ─── Events ───────────────────────────────────────────────────────────────────
abstract class CaisseEvent extends Equatable {
  @override List<Object?> get props => [];
}

class AddItemToCart extends CaisseEvent {
  final SaleItem item;
  AddItemToCart(this.item);
  @override List<Object> get props => [item];
}

class RemoveItemFromCart extends CaisseEvent {
  final String productId;
  RemoveItemFromCart(this.productId);
  @override List<Object> get props => [productId];
}

class UpdateItemQuantity extends CaisseEvent {
  final String productId;
  final int quantity;
  UpdateItemQuantity(this.productId, this.quantity);
  @override List<Object> get props => [productId, quantity];
}

/// Modifier le prix de vente d'un article (sans impact sur le produit en boutique)
class UpdateItemPrice extends CaisseEvent {
  final String productId;
  final double? customPrice; // null = réinitialiser au prix original
  UpdateItemPrice(this.productId, this.customPrice);
  @override List<Object?> get props => [productId, customPrice];
}

class ApplyCartDiscount extends CaisseEvent {
  final double amount;
  ApplyCartDiscount(this.amount);
  @override List<Object> get props => [amount];
}

class SelectPaymentMethod extends CaisseEvent {
  final PaymentMethod method;
  SelectPaymentMethod(this.method);
  @override List<Object> get props => [method];
}

/// Ajouter un frais à la commande (livraison, expédition…)
class AddOrderFee extends CaisseEvent {
  final OrderFee fee;
  AddOrderFee(this.fee);
  @override List<Object> get props => [fee];
}

/// Supprimer un frais
class RemoveOrderFee extends CaisseEvent {
  final String feeId;
  RemoveOrderFee(this.feeId);
  @override List<Object> get props => [feeId];
}

/// Modifier un frais existant
class UpdateOrderFee extends CaisseEvent {
  final String feeId;
  final String? label;
  final double? amount;
  UpdateOrderFee(this.feeId, {this.label, this.amount});
  @override List<Object?> get props => [feeId, label, amount];
}

class ProcessSale extends CaisseEvent {}
class ClearCart  extends CaisseEvent {}

/// Encaisser une vente (statut: completed) — sauvegarde Hive + Supabase
class CompleteSale extends CaisseEvent {
  final String shopId;
  CompleteSale(this.shopId);
  @override List<Object> get props => [shopId];
}

/// Pré-remplir le panier avec les données d'une commande existante (édition)
class LoadOrderForEdit extends CaisseEvent {
  final Sale order;
  LoadOrderForEdit(this.order);
}

/// Enregistrer en tant que commande e-commerce (statut: scheduled)
class SaveOrder extends CaisseEvent {
  final String shopId;
  SaveOrder(this.shopId);
  @override List<Object> get props => [shopId];
}

/// Mise à jour statut d'une commande existante
class UpdateOrderStatus extends CaisseEvent {
  final String     orderId;
  final SaleStatus status;
  UpdateOrderStatus(this.orderId, this.status);
  @override List<Object> get props => [orderId, status];
}

/// Définit le mode de livraison de la vente en cours (panier).
/// Passer [mode] = null pour effacer (retour à "non défini").
class SetDeliveryMode extends CaisseEvent {
  final DeliveryMode? mode;
  final String? locationId;     // partenaire si mode == partner
  final String? personName;     // livreur si mode == inHouse
  SetDeliveryMode({this.mode, this.locationId, this.personName});
  @override List<Object?> get props => [mode, locationId, personName];
}

/// Définit la date de livraison souhaitée pour la commande en cours.
/// Passer `null` pour la retirer.
class SetDeliveryDate extends CaisseEvent {
  final DateTime? date;
  SetDeliveryDate(this.date);
  @override List<Object?> get props => [date];
}

/// Met à jour, en une seule passe, l'ensemble des détails livraison/expédition
/// d'une commande. Émis depuis le `DeliveryDetailsSheet` à la confirmation.
///
/// - `mode` : pickup / inHouse / partner / shipment.
/// - `locationId` : id de la StockLocation partenaire (mode partner).
/// - `personName` : livreur (inHouse) ou contact partenaire (partner).
/// - `deliveryCity` / `deliveryAddress` : où le client souhaite être livré
///   (peut différer de l'adresse client par défaut).
/// - `shipmentCity` / `shipmentAgency` / `shipmentHandler` : ville d'origine,
///   nom de l'agence (DHL, Express Union…) et personne ayant déposé le colis.
/// - `date` : date de livraison souhaitée. Persistée sur Sale.scheduledAt.
///
/// Si [clear] est vrai, tous les détails livraison sont remis à null.
class SetDeliveryDetails extends CaisseEvent {
  final DeliveryMode? mode;
  final String?       locationId;
  final String?       personName;
  final String?       deliveryCity;
  final String?       deliveryAddress;
  final String?       shipmentCity;
  final String?       shipmentAgency;
  final String?       shipmentHandler;
  final DateTime?     date;
  final bool          clear;
  SetDeliveryDetails({
    this.mode,
    this.locationId,
    this.personName,
    this.deliveryCity,
    this.deliveryAddress,
    this.shipmentCity,
    this.shipmentAgency,
    this.shipmentHandler,
    this.date,
    this.clear = false,
  });
  @override List<Object?> get props => [
    mode, locationId, personName,
    deliveryCity, deliveryAddress,
    shipmentCity, shipmentAgency, shipmentHandler,
    date, clear,
  ];
}

/// Modifier le taux de TVA (0–100)
class SetTaxRate extends CaisseEvent {
  final double rate; // ex: 19.25
  SetTaxRate(this.rate);
  @override List<Object> get props => [rate];
}

/// Sélectionner / désélectionner un client
class SetSelectedClient extends CaisseEvent {
  final Client? client;
  SetSelectedClient(this.client);
  @override List<Object?> get props => [client];
}

// ─── State ────────────────────────────────────────────────────────────────────
class CaisseState extends Equatable {
  final List<SaleItem> items;
  final double         discountAmount;
  final List<OrderFee> fees;
  final PaymentMethod  paymentMethod;
  final bool           isProcessing;
  final String?        error;
  final bool           saleCompleted;
  final double         taxRate;        // taux TVA en % (défaut 0)
  final Client?        selectedClient; // client associé à la vente
  final bool?          orderSaved;
  final String?        editingOrderId;
  final Sale?          lastCompletedSale; // vente encaissée (pour reçu PDF)

  /// Mode de livraison choisi pour la vente en cours. `null` = non défini.
  final DeliveryMode?  deliveryMode;
  final String?        deliveryLocationId;
  final String?        deliveryPersonName;

  /// Date de livraison souhaitée par le client (programmée ou immédiate).
  /// Persistée sur la commande via `Sale.scheduledAt`.
  final DateTime?      deliveryDate;

  /// Détails livraison/expédition saisis dans le DeliveryDetailsSheet.
  /// Persistés sur Sale via les nouveaux champs (cf. hotfix_029).
  final String?        deliveryCity;
  final String?        deliveryAddress;
  final String?        shipmentCity;
  final String?        shipmentAgency;
  final String?        shipmentHandler;

  const CaisseState({
    this.items          = const [],
    this.discountAmount = 0,
    this.fees           = const [],
    this.paymentMethod  = PaymentMethod.cash,
    this.isProcessing   = false,
    this.error,
    this.saleCompleted  = false,
    this.taxRate        = 0,
    this.selectedClient,
    this.orderSaved,
    this.editingOrderId,
    this.lastCompletedSale,
    this.deliveryMode,
    this.deliveryLocationId,
    this.deliveryPersonName,
    this.deliveryDate,
    this.deliveryCity,
    this.deliveryAddress,
    this.shipmentCity,
    this.shipmentAgency,
    this.shipmentHandler,
  });

  double get subtotal    => items.fold(0.0, (s, i) => s + i.subtotal);
  /// Somme des frais (livraison, emballage…). Absorbés par la boutique :
  /// ne sont PAS ajoutés au total facturé au client.
  double get totalFees   => fees.fold(0.0, (s, f) => s + f.amount);
  double get taxAmount   => (subtotal - discountAmount) * (taxRate ?? 0.0) / 100;
  /// Total facturé au client = articles (après remise) + TVA.
  /// Les frais sont des dépenses internes (répartis sur le prix de revient
  /// dans le dashboard), pas une ligne ajoutée à la facture.
  double get total       => subtotal - discountAmount + taxAmount;
  int    get itemCount   => items.fold(0, (s, i) => s + i.quantity);

  /// Articles avec alerte prix
  List<SaleItem> get priceAlerts =>
      items.where((i) => i.isPriceAlertTriggered).toList();

  CaisseState copyWith({
    List<SaleItem>? items,
    double? discountAmount,
    List<OrderFee>? fees,
    PaymentMethod? paymentMethod,
    bool? isProcessing,
    String? error,
    bool? saleCompleted,
    double? taxRate,
    Client? selectedClient,
    bool clearClient = false,
    bool? orderSaved,
    String? editingOrderId,
    bool clearEditingOrderId = false,
    Sale? lastCompletedSale,
    DeliveryMode? deliveryMode,
    String? deliveryLocationId,
    String? deliveryPersonName,
    DateTime? deliveryDate,
    String? deliveryCity,
    String? deliveryAddress,
    String? shipmentCity,
    String? shipmentAgency,
    String? shipmentHandler,
    bool clearDelivery = false,
    bool clearDeliveryDate = false,
  }) => CaisseState(
    items:          items          ?? this.items,
    discountAmount: discountAmount ?? this.discountAmount,
    fees:           fees           ?? this.fees,
    paymentMethod:  paymentMethod  ?? this.paymentMethod,
    isProcessing:   isProcessing   ?? this.isProcessing,
    error:          error,
    saleCompleted:  saleCompleted  ?? this.saleCompleted,
    taxRate:        taxRate        ?? this.taxRate ?? 0.0,
    selectedClient: clearClient ? null : selectedClient ?? this.selectedClient,
    orderSaved:     orderSaved ?? false,
    // Préserver l'id d'édition à travers les copyWith — sans ce champ,
    // toute mutation du panier (ajout article, prix, etc.) le faisait retomber
    // à null, et Save créait un nouvel ordre au lieu de mettre à jour → doublon.
    editingOrderId: clearEditingOrderId
        ? null
        : (editingOrderId ?? this.editingOrderId),
    lastCompletedSale:  lastCompletedSale ?? this.lastCompletedSale,
    deliveryMode:       clearDelivery ? null
                        : (deliveryMode ?? this.deliveryMode),
    deliveryLocationId: clearDelivery ? null
                        : (deliveryLocationId ?? this.deliveryLocationId),
    deliveryPersonName: clearDelivery ? null
                        : (deliveryPersonName ?? this.deliveryPersonName),
    deliveryDate:       clearDeliveryDate || clearDelivery ? null
                        : (deliveryDate ?? this.deliveryDate),
    deliveryCity:       clearDelivery ? null
                        : (deliveryCity ?? this.deliveryCity),
    deliveryAddress:    clearDelivery ? null
                        : (deliveryAddress ?? this.deliveryAddress),
    shipmentCity:       clearDelivery ? null
                        : (shipmentCity ?? this.shipmentCity),
    shipmentAgency:     clearDelivery ? null
                        : (shipmentAgency ?? this.shipmentAgency),
    shipmentHandler:    clearDelivery ? null
                        : (shipmentHandler ?? this.shipmentHandler),
  );

  @override
  List<Object?> get props =>
      [items, discountAmount, fees, paymentMethod, isProcessing, error,
       saleCompleted, taxRate, selectedClient, orderSaved, editingOrderId,
       lastCompletedSale,
       deliveryMode, deliveryLocationId, deliveryPersonName, deliveryDate,
       deliveryCity, deliveryAddress,
       shipmentCity, shipmentAgency, shipmentHandler];
}

// ─── Bloc ─────────────────────────────────────────────────────────────────────
class CaisseBloc extends Bloc<CaisseEvent, CaisseState> {
  CaisseBloc() : super(const CaisseState()) {
    on<AddItemToCart>(_onAdd);
    on<RemoveItemFromCart>(_onRemove);
    on<UpdateItemQuantity>(_onUpdate);
    on<UpdateItemPrice>(_onUpdatePrice);
    on<ApplyCartDiscount>(_onDiscount);
    on<AddOrderFee>(_onAddFee);
    on<RemoveOrderFee>(_onRemoveFee);
    on<UpdateOrderFee>(_onUpdateFee);
    on<SelectPaymentMethod>(_onPayment);
    on<ProcessSale>(_onProcess);
    on<ClearCart>(_onClear);
    on<SetTaxRate>(_onSetTaxRate);
    on<SetSelectedClient>(_onSetClient);
    on<SaveOrder>(_onSaveOrder);
    on<UpdateOrderStatus>(_onUpdateOrderStatus);
    on<SetDeliveryMode>((event, emit) {
      if (event.mode == null) {
        emit(state.copyWith(clearDelivery: true));
      } else {
        emit(state.copyWith(
          deliveryMode:       event.mode,
          deliveryLocationId: event.locationId,
          deliveryPersonName: event.personName,
        ));
      }
    });
    on<SetDeliveryDate>((event, emit) {
      if (event.date == null) {
        emit(state.copyWith(clearDeliveryDate: true));
      } else {
        emit(state.copyWith(deliveryDate: event.date));
      }
    });
    on<SetDeliveryDetails>((event, emit) {
      if (event.clear) {
        emit(state.copyWith(clearDelivery: true));
        return;
      }
      // Quand on change de mode, on nettoie les champs spécifiques aux autres
      // modes pour éviter qu'un ancien `shipmentAgency` traîne sur une livraison
      // partenaire (et inversement). copyWith ne permet pas de mettre un champ
      // à null individuellement, donc on reconstruit l'état directement.
      final newMode = event.mode ?? state.deliveryMode;
      final isShipment = newMode == DeliveryMode.shipment;
      final isPartner  = newMode == DeliveryMode.partner;
      final isInHouse  = newMode == DeliveryMode.inHouse;
      final isPickup   = newMode == DeliveryMode.pickup;

      emit(CaisseState(
        items:             state.items,
        discountAmount:    state.discountAmount,
        fees:              state.fees,
        paymentMethod:     state.paymentMethod,
        isProcessing:      state.isProcessing,
        error:             null,
        saleCompleted:     state.saleCompleted,
        taxRate:           state.taxRate,
        selectedClient:    state.selectedClient,
        orderSaved:        state.orderSaved,
        editingOrderId:    state.editingOrderId,
        lastCompletedSale: state.lastCompletedSale,
        deliveryMode:       newMode,
        deliveryLocationId: isPartner
            ? (event.locationId ?? state.deliveryLocationId)
            : null,
        deliveryPersonName: (isInHouse || isPartner)
            ? (event.personName ?? state.deliveryPersonName)
            : null,
        // Pickup = retrait : pas d'adresse de livraison.
        deliveryCity:    isPickup ? null
            : (event.deliveryCity    ?? state.deliveryCity),
        deliveryAddress: isPickup ? null
            : (event.deliveryAddress ?? state.deliveryAddress),
        shipmentCity:    isShipment
            ? (event.shipmentCity ?? state.shipmentCity)
            : null,
        shipmentAgency:  isShipment
            ? (event.shipmentAgency ?? state.shipmentAgency)
            : null,
        shipmentHandler: isShipment
            ? (event.shipmentHandler ?? state.shipmentHandler)
            : null,
        deliveryDate:    event.date ?? state.deliveryDate,
      ));
    });
    on<LoadOrderForEdit>(_onLoadOrderForEdit);
    on<CompleteSale>(_onCompleteSale);
  }

  void _onAdd(AddItemToCart event, Emitter<CaisseState> emit) {
    final idx = state.items.indexWhere(
            (i) => i.productId == event.item.productId);
    final items = List<SaleItem>.from(state.items);
    if (idx >= 0) {
      items[idx] = items[idx].copyWith(
          quantity: items[idx].quantity + event.item.quantity);
    } else {
      items.add(event.item);
    }
    emit(state.copyWith(items: items));
  }

  void _onRemove(RemoveItemFromCart event, Emitter<CaisseState> emit) =>
      emit(state.copyWith(
          items: state.items
              .where((i) => i.productId != event.productId)
              .toList()));

  void _onUpdate(UpdateItemQuantity event, Emitter<CaisseState> emit) {
    if (event.quantity <= 0) {
      add(RemoveItemFromCart(event.productId));
      return;
    }
    final items = state.items
        .map((i) => i.productId == event.productId
        ? i.copyWith(quantity: event.quantity)
        : i)
        .toList();
    emit(state.copyWith(items: items));
  }

  void _onUpdatePrice(UpdateItemPrice event, Emitter<CaisseState> emit) {
    final items = state.items
        .map((i) => i.productId == event.productId
        ? i.copyWith(
      customPrice: event.customPrice,
      clearCustomPrice: event.customPrice == null,
    )
        : i)
        .toList();
    emit(state.copyWith(items: items));
  }

  void _onDiscount(ApplyCartDiscount event, Emitter<CaisseState> emit) =>
      emit(state.copyWith(discountAmount: event.amount));

  void _onAddFee(AddOrderFee event, Emitter<CaisseState> emit) {
    final fees = List<OrderFee>.from(state.fees)..add(event.fee);
    emit(state.copyWith(fees: fees));
  }

  void _onRemoveFee(RemoveOrderFee event, Emitter<CaisseState> emit) {
    final fees = state.fees.where((f) => f.id != event.feeId).toList();
    emit(state.copyWith(fees: fees));
  }

  void _onUpdateFee(UpdateOrderFee event, Emitter<CaisseState> emit) {
    final fees = state.fees.map((f) => f.id == event.feeId
        ? f.copyWith(label: event.label, amount: event.amount)
        : f).toList();
    emit(state.copyWith(fees: fees));
  }

  void _onPayment(SelectPaymentMethod event, Emitter<CaisseState> emit) =>
      emit(state.copyWith(paymentMethod: event.method));

  Future<void> _onProcess(ProcessSale event, Emitter<CaisseState> emit) async {
    emit(state.copyWith(isProcessing: true));
    await Future.delayed(const Duration(milliseconds: 500));
    emit(state.copyWith(isProcessing: false, saleCompleted: true));
  }

  /// Encaisser : sauvegarde Hive + Supabase avec status completed
  Future<void> _onCompleteSale(CompleteSale event, Emitter<CaisseState> emit) async {
    // Règle métier : toute vente doit être rattachée à un client enregistré.
    if (state.selectedClient == null) {
      emit(state.copyWith(
          error: 'Sélectionne un client avant de valider la vente.'));
      return;
    }

    // Cohérence des champs livraison/expédition avec le mode choisi.
    final deliveryErr = _validateDelivery(state);
    if (deliveryErr != null) {
      emit(state.copyWith(error: deliveryErr));
      return;
    }

    emit(state.copyWith(isProcessing: true));
    try {
      // Contrôle stock (partenaire OU boutique) — empêche de valider la
      // vente quand un article a une quantité demandée supérieure au stock
      // disponible. Évite stock négatif et survente.
      final stockErr = _validateStock(
        event.shopId,
        state.items,
        locationId: state.deliveryMode == DeliveryMode.partner
            ? state.deliveryLocationId
            : null,
      );
      if (stockErr != null) {
        emit(state.copyWith(isProcessing: false, error: stockErr));
        return;
      }

      final ds = SaleLocalDatasource();
      final sale = Sale(
        id:             'sale_${DateTime.now().millisecondsSinceEpoch}',
        shopId:         event.shopId,
        items:          state.items,
        discountAmount: state.discountAmount,
        taxRate:        state.taxRate,
        fees:           state.fees.map((f) =>
            {'id': f.id, 'label': f.label, 'amount': f.amount}).toList(),
        paymentMethod:  state.paymentMethod,
        status:         SaleStatus.completed,
        clientId:       state.selectedClient?.id,
        clientName:     state.selectedClient?.name,
        clientPhone:    state.selectedClient?.phone,
        createdAt:      DateTime.now(),
        scheduledAt:    state.deliveryDate,
        deliveryMode:       state.deliveryMode,
        deliveryLocationId: state.deliveryLocationId,
        deliveryPersonName: state.deliveryPersonName,
        deliveryCity:       state.deliveryCity,
        deliveryAddress:    state.deliveryAddress,
        shipmentCity:       state.shipmentCity,
        shipmentAgency:     state.shipmentAgency,
        shipmentHandler:    state.shipmentHandler,
        // Trace l'auteur de la vente : un vendeur (role=user) ne verra que
        // ses propres ventes dans le dashboard (cf. dashDataProvider filter).
        createdByUserId: Supabase.instance.client.auth.currentUser?.id,
      );
      await ds.saveOrder(sale);

      // Une vente immédiatement "completed" n'a pas besoin de rappel futur,
      // mais si la date est dans le futur on programme quand même (le client
      // sera livré plus tard).
      await DeliveryReminderService.scheduleFor(sale);

      // Décrémenter le stock : location partenaire si livraison partner,
      // sinon la variante de la boutique (comportement historique).
      await decrementStock(
        event.shopId, state.items,
        orderId:            sale.id,
        deliveryLocationId: sale.deliveryMode == DeliveryMode.partner
            ? sale.deliveryLocationId
            : null,
      );

      await ActivityLogService.log(
        action:      'sale_completed',
        targetType:  'sale',
        targetId:    sale.id,
        targetLabel: sale.clientName,
        shopId:      event.shopId,
        details: {
          'item_count':     sale.items.length,
          'total':          sale.total,
          'payment_method': sale.paymentMethod.name,
          'reference':      sale.id,
          if (sale.deliveryMode == DeliveryMode.partner
              && (sale.deliveryLocationId ?? '').isNotEmpty)
            'delivery_partner': sale.deliveryLocationId,
        },
      );
      emit(state.copyWith(
        isProcessing:      false,
        saleCompleted:     true,
        lastCompletedSale: sale,
        clearDelivery:     true, // reset mode livraison pour la prochaine vente
        clearDeliveryDate: true,
      ));
    } catch (e) {
      emit(state.copyWith(isProcessing: false, error: e.toString()));
    }
  }

  /// Valide que les détails de livraison sont cohérents avec le mode choisi.
  /// - `inHouse`  → ville requise.
  /// - `partner`  → location partenaire + ville requises.
  /// - `shipment` → ville destinataire + agence + responsable requis.
  /// Retourne un message FR si invalide, null si OK.
  static String? _validateDelivery(CaisseState s) {
    switch (s.deliveryMode) {
      case null:
      case DeliveryMode.pickup:
        return null;
      case DeliveryMode.inHouse:
        if ((s.deliveryCity ?? '').trim().isEmpty) {
          return 'Ville de livraison requise (livraison équipe). '
              'Ouvrez "Détails de livraison" dans le panier.';
        }
        return null;
      case DeliveryMode.partner:
        if ((s.deliveryLocationId ?? '').isEmpty) {
          return 'Partenaire de livraison non sélectionné. '
              'Ouvrez "Détails de livraison" dans le panier.';
        }
        if ((s.deliveryCity ?? '').trim().isEmpty) {
          return 'Ville de livraison requise (partenaire). '
              'Ouvrez "Détails de livraison" dans le panier.';
        }
        return null;
      case DeliveryMode.shipment:
        if ((s.deliveryCity ?? '').trim().isEmpty) {
          return 'Ville du destinataire requise (expédition). '
              'Ouvrez "Détails de livraison" dans le panier.';
        }
        if ((s.shipmentAgency ?? '').trim().isEmpty) {
          return 'Agence d\'expédition requise. '
              'Ouvrez "Détails de livraison" dans le panier.';
        }
        if ((s.shipmentHandler ?? '').trim().isEmpty) {
          return 'Responsable de l\'envoi requis. '
              'Ouvrez "Détails de livraison" dans le panier.';
        }
        return null;
    }
  }

  /// Valide que le stock disponible suffit pour satisfaire tous les items.
  ///
  /// - [locationId] non-null → mode livraison partenaire : on vérifie le
  ///   stock_level à cette location.
  /// - [locationId] null → vente boutique : on vérifie le `stockAvailable`
  ///   de la variante du produit dans la boutique courante.
  ///
  /// Retourne un message d'erreur FR si bloqué, null si OK.
  static String? _validateStock(
      String shopId, List<SaleItem> items, {String? locationId}) {
    final products = AppDatabase.getProductsForShop(shopId);
    for (final item in items) {
      // Résoudre la variante : un SaleItem.productId peut référencer soit
      // l'id de la variante (cas standard), soit l'id du produit (legacy
      // produits sans variantes).
      String?         variantId;
      ProductVariant? variant;
      for (final p in products) {
        for (final v in p.variants) {
          if (v.id == item.productId) {
            variantId = v.id;
            variant   = v;
            break;
          }
        }
        if (variant != null) break;
        if (p.id == item.productId && p.variants.isNotEmpty) {
          variantId = p.variants.first.id;
          variant   = p.variants.first;
          break;
        }
      }
      // Variante introuvable : on ignore (produit éphémère / non géré).
      if (variantId == null || variant == null) continue;

      final int avail;
      if (locationId != null && locationId.isNotEmpty) {
        final lvl = AppDatabase.getStockLevel(variantId, locationId);
        avail = lvl?.stockAvailable ?? 0;
      } else {
        avail = variant.stockAvailable;
      }

      if (avail < item.quantity) {
        final source = locationId != null && locationId.isNotEmpty
            ? 'chez le partenaire'
            : 'en boutique';
        return 'Stock insuffisant $source pour "${item.productName}" '
            '(disponible : $avail, demandé : ${item.quantity})';
      }
    }
    return null;
  }

  /// Décrémente le stock pour chaque article vendu.
  /// - Si [deliveryLocationId] est fourni (mode partenaire) → décrément depuis
  ///   cette location via `StockService.saleFromLocation` (stockLevel seul).
  /// - Sinon → décrément depuis la variante de la boutique
  ///   via `StockService.sale` (comportement historique).
  static Future<void> decrementStock(String shopId, List<SaleItem> items,
      {String? orderId, String? deliveryLocationId}) async {
    final products = AppDatabase.getProductsForShop(shopId);
    for (final item in items) {
      String? resolvedProductId;
      String variantId = item.productId;
      for (final p in products) {
        for (final v in p.variants) {
          if (v.id == item.productId) { resolvedProductId = p.id; break; }
        }
        if (resolvedProductId != null) break;
        if (p.id == item.productId) {
          resolvedProductId = p.id;
          variantId = p.variants.isNotEmpty
              ? (p.variants.first.id ?? item.productId)
              : item.productId;
          break;
        }
      }
      if (resolvedProductId == null) continue;

      if (deliveryLocationId != null && deliveryLocationId.isNotEmpty) {
        await StockService.saleFromLocation(
          locationId: deliveryLocationId,
          variantId:  variantId,
          quantity:   item.quantity,
          shopId:     shopId,
          productId:  resolvedProductId,
          orderId:    orderId,
        );
      } else {
        await StockService.sale(
          shopId:    shopId,
          productId: resolvedProductId,
          variantId: variantId,
          quantity:  item.quantity,
          orderId:   orderId,
        );
      }
    }
  }

  /// Restaure le stock pour chaque article (inverse de decrementStock).
  /// Utilise la bonne source selon [deliveryLocationId].
  static Future<void> restoreStock(String shopId, List<SaleItem> items,
      {String? orderId, String? deliveryLocationId}) async {
    final products = AppDatabase.getProductsForShop(shopId);
    for (final item in items) {
      String? resolvedProductId;
      String variantId = item.productId;
      for (final p in products) {
        for (final v in p.variants) {
          if (v.id == item.productId) { resolvedProductId = p.id; break; }
        }
        if (resolvedProductId != null) break;
        if (p.id == item.productId) {
          resolvedProductId = p.id;
          variantId = p.variants.isNotEmpty
              ? (p.variants.first.id ?? item.productId)
              : item.productId;
          break;
        }
      }
      if (resolvedProductId == null) continue;

      if (deliveryLocationId != null && deliveryLocationId.isNotEmpty) {
        await StockService.reverseSaleFromLocation(
          locationId: deliveryLocationId,
          variantId:  variantId,
          quantity:   item.quantity,
          shopId:     shopId,
          productId:  resolvedProductId,
          orderId:    orderId,
        );
      } else {
        await StockService.reverseSale(
          shopId:    shopId,
          productId: resolvedProductId,
          variantId: variantId,
          quantity:  item.quantity,
          orderId:   orderId,
        );
      }
    }
  }

  void _onClear(ClearCart event, Emitter<CaisseState> emit) =>
      emit(const CaisseState());

  void _onSetTaxRate(SetTaxRate event, Emitter<CaisseState> emit) =>
      emit(state.copyWith(taxRate: event.rate));

  void _onSetClient(SetSelectedClient event, Emitter<CaisseState> emit) =>
      emit(event.client == null
          ? state.copyWith(clearClient: true)
          : state.copyWith(selectedClient: event.client));

  /// Pré-remplit le panier avec les données d'une commande existante
  void _onLoadOrderForEdit(LoadOrderForEdit event, Emitter<CaisseState> emit) {
    final o = event.order;

    // Enrichir les items avec les images actuelles depuis Hive
    final products = AppDatabase.getProductsForShop(o.shopId);
    final enrichedItems = o.items.map((item) {
      // Matcher par productId en priorité, sinon par nom (fallback)
      var product = products
          .where((p) => p.id == item.productId)
          .firstOrNull;
      product ??= products
          .where((p) => p.name.toLowerCase() ==
          item.productName.toLowerCase())
          .firstOrNull;

      if (product == null) return item;

      // Trouver la variante si applicable (par nom)
      final variant = item.variantName != null && product.variants.isNotEmpty
          ? product.variants
          .where((v) => v.name.toLowerCase() ==
          item.variantName!.toLowerCase())
          .firstOrNull
          : null;

      // Priorité : image variante → image principale → image produit
      final imageUrl = variant?.imageUrl?.isNotEmpty == true
          ? variant!.imageUrl
          : (product.mainImageUrl?.isNotEmpty == true
          ? product.mainImageUrl
          : product.imageUrl);

      if (imageUrl == null || imageUrl.isEmpty) return item;
      return item.copyWith(imageUrl: imageUrl);
    }).toList();

    // Restaurer les frais de commande depuis le modèle Sale
    final restoredFees = o.fees.map((f) => OrderFee(
      id:     f['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      label:  f['label']?.toString() ?? '',
      amount: (f['amount'] as num?)?.toDouble() ?? 0,
    )).toList();

    emit(state.copyWith(
      items:          enrichedItems,
      discountAmount: o.discountAmount,
      taxRate:        o.taxRate,
      fees:           restoredFees,
      selectedClient: o.clientId != null
          ? Client(
        id:        o.clientId!,
        storeId:   o.shopId,
        name:      o.clientName ?? '',
        phone:     o.clientPhone,
        createdAt: o.createdAt,
      )
          : null,
      // Restaurer la date de livraison + le mode pour pré-remplir l'UI.
      deliveryDate:       o.scheduledAt,
      deliveryMode:       o.deliveryMode,
      deliveryLocationId: o.deliveryLocationId,
      deliveryPersonName: o.deliveryPersonName,
      deliveryCity:       o.deliveryCity,
      deliveryAddress:    o.deliveryAddress,
      shipmentCity:       o.shipmentCity,
      shipmentAgency:     o.shipmentAgency,
      shipmentHandler:    o.shipmentHandler,
      editingOrderId: o.id,
      orderSaved:     null,
      saleCompleted:  false,
      isProcessing:   false,
      error:          null,
    ));
  }

  Future<void> _onSaveOrder(SaveOrder event, Emitter<CaisseState> emit) async {
    // Règle métier : toute commande doit être rattachée à un client enregistré.
    if (state.selectedClient == null) {
      emit(state.copyWith(
          error: 'Sélectionne un client avant d\'enregistrer la commande.'));
      return;
    }

    // Cohérence des champs livraison/expédition avec le mode choisi.
    final deliveryErr = _validateDelivery(state);
    if (deliveryErr != null) {
      emit(state.copyWith(error: deliveryErr));
      return;
    }

    // Contrôle stock — bloque l'enregistrement d'une commande programmée si
    // une variante a moins de stock disponible que la quantité demandée.
    final stockErr = _validateStock(
      event.shopId,
      state.items,
      locationId: state.deliveryMode == DeliveryMode.partner
          ? state.deliveryLocationId
          : null,
    );
    if (stockErr != null) {
      emit(state.copyWith(error: stockErr));
      return;
    }

    emit(state.copyWith(isProcessing: true));
    try {
      final ds      = SaleLocalDatasource();
      final isEdit  = state.editingOrderId != null;

      if (isEdit) {
        // ── Mode ÉDITION : mise à jour de la commande existante ──
        final existing = ds.getOrders(event.shopId)
            .firstWhere((o) => o.id == state.editingOrderId);
        final updated = Sale(
          id:             state.editingOrderId,
          shopId:         event.shopId,
          items:          state.items,
          discountAmount: state.discountAmount,
          taxRate:        state.taxRate ?? 0,
          fees:           state.fees.map((f) =>
              {'id': f.id, 'label': f.label, 'amount': f.amount}).toList(),
          paymentMethod:  state.paymentMethod,
          status:         existing.status, // garder le statut original
          clientId:       state.selectedClient?.id,
          clientName:     state.selectedClient?.name,
          clientPhone:    state.selectedClient?.phone,
          createdAt:      existing.createdAt, // garder la date originale
          notes:          existing.notes,
          scheduledAt:    state.deliveryDate ?? existing.scheduledAt,
          // Si l'utilisateur a modifié le mode dans le state → on l'utilise ;
          // sinon on conserve celui de la commande existante.
          deliveryMode:       state.deliveryMode ?? existing.deliveryMode,
          deliveryLocationId: state.deliveryLocationId
              ?? existing.deliveryLocationId,
          deliveryPersonName: state.deliveryPersonName
              ?? existing.deliveryPersonName,
          deliveryCity:       state.deliveryCity    ?? existing.deliveryCity,
          deliveryAddress:    state.deliveryAddress ?? existing.deliveryAddress,
          shipmentCity:       state.shipmentCity    ?? existing.shipmentCity,
          shipmentAgency:     state.shipmentAgency  ?? existing.shipmentAgency,
          shipmentHandler:    state.shipmentHandler ?? existing.shipmentHandler,
          // Édition : on garde l'auteur original (ne change pas après update).
          createdByUserId: existing.createdByUserId,
        );
        await ds.updateOrder(updated);
        // Reprogrammer le rappel (remplace le précédent grâce à l'id déterministe)
        await DeliveryReminderService.scheduleFor(updated);
      } else {
        // ── Mode CRÉATION : nouvelle commande ──
        final order = Sale(
          id:             'order_${DateTime.now().millisecondsSinceEpoch}',
          shopId:         event.shopId,
          items:          state.items,
          discountAmount: state.discountAmount,
          taxRate:        state.taxRate ?? 0,
          fees:           state.fees.map((f) =>
              {'id': f.id, 'label': f.label, 'amount': f.amount}).toList(),
          paymentMethod:  state.paymentMethod,
          status:         SaleStatus.scheduled,
          clientId:       state.selectedClient?.id,
          clientName:     state.selectedClient?.name,
          clientPhone:    state.selectedClient?.phone,
          createdAt:      DateTime.now(),
          scheduledAt:    state.deliveryDate,
          // Mode de livraison choisi sur la page panier (e-commerce) avant
          // enregistrement de la commande programmée.
          deliveryMode:       state.deliveryMode,
          deliveryLocationId: state.deliveryLocationId,
          deliveryPersonName: state.deliveryPersonName,
          deliveryCity:       state.deliveryCity,
          deliveryAddress:    state.deliveryAddress,
          shipmentCity:       state.shipmentCity,
          shipmentAgency:     state.shipmentAgency,
          shipmentHandler:    state.shipmentHandler,
          // Trace l'auteur (vendeur) de la commande pour le filtre dashboard.
          createdByUserId: Supabase.instance.client.auth.currentUser?.id,
        );
        await ds.saveOrder(order);
        // Programmer la notification de rappel à la date de livraison
        await DeliveryReminderService.scheduleFor(order);
        await ActivityLogService.log(
          action:      'sale_completed',
          targetType:  'sale',
          targetId:    order.id,
          targetLabel: order.clientName,
          shopId:      event.shopId,
          details: {
            'item_count':     order.items.length,
            'total':          state.total,
            'payment_method': order.paymentMethod.name,
            'reference':      order.id,
            'scheduled':      true,
          },
        );
      }
      emit(state.copyWith(
          isProcessing:        false,
          orderSaved:          true,
          clearEditingOrderId: true)); // réinitialiser le mode édition
    } catch (e) {
      emit(state.copyWith(isProcessing: false,
          error: e.toString()));
    }
  }

  Future<void> _onUpdateOrderStatus(
      UpdateOrderStatus event, Emitter<CaisseState> emit) async {
    // La compensation de stock (restauration si completed → autre, ou
    // décrément si autre → completed) est centralisée dans
    // SaleLocalDatasource.updateOrderStatus pour couvrir tous les chemins
    // de l'app qui modifient le statut d'une commande.
    await SaleLocalDatasource().updateOrderStatus(event.orderId, event.status);
  }
}