import 'package:equatable/equatable.dart';
import '../entities/shop_summary.dart';
import 'get_my_shops_usecase.dart';

class UpdateShopUseCase {
  final ShopSelectorRepository repository;
  const UpdateShopUseCase(this.repository);
  Future<ShopSummary> call(UpdateShopParams p) =>
      repository.updateShop(p.shopId, p.toMap());
}

class UpdateShopParams extends Equatable {
  final String shopId;
  final String? name, sector, currency, country, phone, email;
  const UpdateShopParams({
    required this.shopId,
    this.name, this.sector, this.currency, this.country,
    this.phone, this.email,
  });

  /// N'inclut que les champs non-null → update partiel.
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (name     != null) m['name']     = name;
    if (sector   != null) m['sector']   = sector;
    if (currency != null) m['currency'] = currency;
    if (country  != null) m['country']  = country;
    if (phone    != null) m['phone']    = phone;
    if (email    != null) m['email']    = email;
    return m;
  }

  @override
  List<Object?> get props => [shopId, name, sector, currency, country, phone, email];
}
