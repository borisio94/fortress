import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/data/datasources/auth_remote_datasource.dart';
import '../../features/auth/data/repositories/auth_repository_impl.dart';
import '../../features/auth/domain/repositories/auth_repository.dart';
import '../../features/auth/domain/usecases/login_usecase.dart';
import '../../features/auth/domain/usecases/register_usecase.dart';
import '../../features/auth/domain/usecases/logout_usecase.dart';
import '../../features/auth/presentation/bloc/auth_bloc.dart';
import '../../features/inventaire/data/repositories/product_local_datasource.dart';
import '../../features/inventaire/data/repositories/product_remote_datasource.dart';
import '../../features/inventaire/data/repositories/product_repository_impl.dart';
import '../../features/inventaire/domain/repositories/product_repository.dart';
import '../../features/inventaire/domain/usecases/get_products_usecase.dart';
import '../../features/inventaire/domain/usecases/add_product_usecase.dart';
import '../../features/inventaire/domain/usecases/update_stock_usecase.dart';
import '../../features/inventaire/presentation/bloc/inventaire_bloc.dart';
import '../../features/crm/data/repositories/client_repository_impl.dart';
import '../../features/crm/domain/repositories/client_repository.dart';
import '../../features/crm/domain/usecases/get_clients_usecase.dart';
import '../../features/crm/presentation/bloc/crm_bloc.dart';
import '../../features/caisse/data/repositories/sale_local_datasource.dart';
import '../../features/caisse/data/repositories/sale_repository_impl.dart';
import '../../features/caisse/domain/repositories/sale_repository.dart';
import '../../features/caisse/presentation/bloc/caisse_bloc.dart';
import '../../features/hub_central/data/repositories/hub_repository_impl.dart';
import '../../features/hub_central/domain/usecases/get_all_shops_stats_usecase.dart';
import '../../features/hub_central/presentation/bloc/hub_bloc.dart';
import '../../features/shop_selector/data/repositories/shop_selector_repo_impl.dart';
import '../../features/shop_selector/domain/usecases/get_my_shops_usecase.dart';
import '../../features/shop_selector/domain/usecases/create_shop_usecase.dart';
import '../../features/shop_selector/domain/usecases/update_shop_usecase.dart';

// ─── Auth ──────────────────────────────────────────────────────────────────────
// Supabase Auth — production ready, pas de Dio
final authRemoteDsProvider = Provider<AuthRemoteDataSource>((_) =>
    AuthRemoteDataSourceMock());

final authRepositoryProvider = Provider<AuthRepository>((ref) =>
    AuthRepositoryImpl(ref.read(authRemoteDsProvider)));

final authBlocProvider = Provider<AuthBloc>((ref) {
  final repo = ref.read(authRepositoryProvider);
  final bloc = AuthBloc(
    loginUseCase:    LoginUseCase(repo),
    registerUseCase: RegisterUseCase(repo),
    logoutUseCase:   LogoutUseCase(repo),
    authRepository:  repo,
  );
  ref.onDispose(bloc.close);
  return bloc;
});

// ─── Shop Selector ─────────────────────────────────────────────────────────────
// Pas de Dio — AppDatabase + Hive offline-first
final shopSelectorRepoProvider = Provider<ShopSelectorRepository>((_) =>
    ShopSelectorRepositoryImpl());

final getMyShopsUseCaseProvider = Provider<GetMyShopsUseCase>((ref) =>
    GetMyShopsUseCase(ref.read(shopSelectorRepoProvider)));

final createShopUseCaseProvider = Provider<CreateShopUseCase>((ref) =>
    CreateShopUseCase(ref.read(shopSelectorRepoProvider)));

final updateShopUseCaseProvider = Provider<UpdateShopUseCase>((ref) =>
    UpdateShopUseCase(ref.read(shopSelectorRepoProvider)));

// ─── Inventaire ────────────────────────────────────────────────────────────────
final productRemoteDsProvider = Provider<ProductRemoteDataSource>((_) =>
    ProductRemoteDataSourceImpl());

final productLocalDsProvider = Provider<ProductLocalDataSource>((_) =>
    ProductLocalDataSourceImpl());

final productRepositoryProvider = Provider<ProductRepository>((ref) =>
    ProductRepositoryImpl(
      remote: ref.read(productRemoteDsProvider),
      local:  ref.read(productLocalDsProvider),
    ));

final inventaireBlocProvider =
    Provider.family<InventaireBloc, String>((ref, shopId) => InventaireBloc(
      getProducts: GetProductsUseCase(ref.read(productRepositoryProvider)),
      addProduct:  AddProductUseCase(ref.read(productRepositoryProvider)),
      updateStock: UpdateStockUseCase(ref.read(productRepositoryProvider)),
      repository:  ref.read(productRepositoryProvider),
    ));

// ─── CRM ───────────────────────────────────────────────────────────────────────
final clientRepositoryProvider = Provider<ClientRepository>((_) =>
    const ClientRepositoryImpl());

final crmBlocProvider = Provider.family<CrmBloc, String>((ref, shopId) =>
    CrmBloc());

// ─── Caisse ────────────────────────────────────────────────────────────────────
final saleLocalDsProvider = Provider<SaleLocalDatasource>((_) =>
    SaleLocalDatasource());

final saleRepositoryProvider = Provider<SaleRepository>((ref) =>
    SaleRepositoryImpl(local: ref.read(saleLocalDsProvider)));

final caisseBlocProvider = Provider<CaisseBloc>((ref) {
  final bloc = CaisseBloc();
  ref.onDispose(bloc.close);
  return bloc;
});

// ─── Hub ───────────────────────────────────────────────────────────────────────
final hubRepositoryProvider = Provider<HubRepository>((_) =>
    HubRepositoryImpl());

final hubBlocProvider = Provider<HubBloc>((ref) =>
    HubBloc(GetAllShopsStatsUseCase(ref.read(hubRepositoryProvider))));
