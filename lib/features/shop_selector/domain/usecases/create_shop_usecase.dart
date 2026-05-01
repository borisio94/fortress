import 'package:equatable/equatable.dart';
import '../entities/shop_summary.dart';
import 'get_my_shops_usecase.dart';

class CreateShopUseCase {
  final ShopSelectorRepository repository;
  const CreateShopUseCase(this.repository);
  Future<ShopSummary> call(CreateShopParams p) => repository.createShop(p.toMap());
}

class CreateShopParams extends Equatable {
  final String name, sector, currency, country;
  final String? phone, email, address;
  const CreateShopParams({
    required this.name, required this.sector,
    required this.currency, required this.country,
    this.phone, this.email, this.address,
  });
  Map<String, dynamic> toMap() => {
    'name': name, 'sector': sector, 'currency': currency,
    'country': country, 'phone': phone, 'email': email, 'address': address,
  };
  @override List<Object?> get props => [name, sector];
}
