import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/entities/shop_summary.dart';
import '../../domain/usecases/get_my_shops_usecase.dart';
import '../../domain/usecases/create_shop_usecase.dart';
import '../../domain/usecases/update_shop_usecase.dart';

// ─── Events ───────────────────────────────────────────────────────────────────
abstract class ShopSelectorEvent extends Equatable {
  @override List<Object?> get props => [];
}
class LoadMyShops extends ShopSelectorEvent {}
class CreateShopRequested extends ShopSelectorEvent {
  final CreateShopParams params;
  CreateShopRequested(this.params);
  @override List<Object> get props => [params];
}
class UpdateShopRequested extends ShopSelectorEvent {
  final UpdateShopParams params;
  UpdateShopRequested(this.params);
  @override List<Object> get props => [params];
}

// ─── States ───────────────────────────────────────────────────────────────────
abstract class ShopSelectorState extends Equatable {
  @override List<Object?> get props => [];
}
class ShopSelectorInitial extends ShopSelectorState {}
class ShopSelectorLoading extends ShopSelectorState {}
class ShopSelectorLoaded extends ShopSelectorState {
  final List<ShopSummary> shops;
  ShopSelectorLoaded(this.shops);
  @override List<Object> get props => [shops];
}
class ShopSelectorError extends ShopSelectorState {
  final String message;
  ShopSelectorError(this.message);
  @override List<Object> get props => [message];
}
class ShopCreated extends ShopSelectorState {
  final ShopSummary shop;
  ShopCreated(this.shop);
  @override List<Object> get props => [shop];
}
class ShopUpdated extends ShopSelectorState {
  final ShopSummary shop;
  ShopUpdated(this.shop);
  @override List<Object> get props => [shop];
}

// ─── Bloc ─────────────────────────────────────────────────────────────────────
class ShopSelectorBloc extends Bloc<ShopSelectorEvent, ShopSelectorState> {
  final GetMyShopsUseCase   getMyShopsUseCase;
  final CreateShopUseCase   createShopUseCase;
  final UpdateShopUseCase   updateShopUseCase;

  ShopSelectorBloc({
    required this.getMyShopsUseCase,
    required this.createShopUseCase,
    required this.updateShopUseCase,
  }) : super(ShopSelectorInitial()) {
    on<LoadMyShops>(_onLoad);
    on<CreateShopRequested>(_onCreate);
    on<UpdateShopRequested>(_onUpdate);
  }

  Future<void> _onLoad(LoadMyShops event, Emitter<ShopSelectorState> emit) async {
    emit(ShopSelectorLoading());
    try {
      final shops = await getMyShopsUseCase();
      debugPrint('[ShopBloc] ${shops.length} boutiques chargées');
      emit(ShopSelectorLoaded(shops));
    } catch (e) {
      debugPrint('[ShopBloc] Erreur: $e');
      emit(ShopSelectorError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  Future<void> _onCreate(CreateShopRequested event, Emitter<ShopSelectorState> emit) async {
    emit(ShopSelectorLoading());
    try {
      final shop = await createShopUseCase(event.params);
      emit(ShopCreated(shop));
    } catch (e) {
      emit(ShopSelectorError(e.toString().replaceAll('Exception: ', '')));
    }
  }

  Future<void> _onUpdate(UpdateShopRequested event, Emitter<ShopSelectorState> emit) async {
    emit(ShopSelectorLoading());
    try {
      final shop = await updateShopUseCase(event.params);
      emit(ShopUpdated(shop));
    } catch (e) {
      emit(ShopSelectorError(e.toString().replaceAll('Exception: ', '')));
    }
  }
}