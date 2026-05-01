import '../entities/sale.dart';

class ApplyDiscountUseCase {
  double call(Sale sale, double discountAmount) {
    return sale.total - discountAmount;
  }
}
