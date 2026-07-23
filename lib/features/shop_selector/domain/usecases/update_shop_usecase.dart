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
  // `sector` VOLONTAIREMENT ABSENT : le type d'établissement est figé à la
  // création. Le retirer du DTO — et pas seulement de l'UI — garantit qu'aucun
  // futur appelant ne pourra le remodifier par inadvertance.
  final String? name, currency, country, phone, whatsappPhone, email;
  const UpdateShopParams({
    required this.shopId,
    this.name, this.currency, this.country,
    this.phone, this.whatsappPhone, this.email,
  });

  /// N'inclut que les champs non-null → update partiel.
  Map<String, dynamic> toMap() {
    final m = <String, dynamic>{};
    if (name     != null) m['name']     = name;
    if (currency != null) m['currency'] = currency;
    if (country  != null) m['country']  = country;
    if (phone    != null) m['phone']    = phone;
    if (whatsappPhone != null) m['whatsapp_phone'] = whatsappPhone;
    if (email    != null) m['email']    = email;
    return m;
  }

  @override
  List<Object?> get props =>
      [shopId, name, currency, country, phone, whatsappPhone, email];
}
