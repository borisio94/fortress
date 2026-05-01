import '../../domain/entities/sale.dart';

class PaymentModel {
  final String        method;
  final double        amount;
  final DateTime      processedAt;

  const PaymentModel({
    required this.method,
    required this.amount,
    required this.processedAt,
  });

  factory PaymentModel.fromMap(Map<String, dynamic> m) => PaymentModel(
    method:      m['method'] as String,
    amount:      (m['amount'] as num).toDouble(),
    processedAt: DateTime.parse(m['processed_at'] as String),
  );

  Map<String, dynamic> toMap() => {
    'method':       method,
    'amount':       amount,
    'processed_at': processedAt.toIso8601String(),
  };

  PaymentMethod toPaymentMethod() => PaymentMethod.values.firstWhere(
      (m) => m.name == method, orElse: () => PaymentMethod.cash);
}
