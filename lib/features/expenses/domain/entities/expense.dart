import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import '../../../caisse/domain/entities/sale.dart'; // PaymentMethod

// ═════════════════════════════════════════════════════════════════════════════
// Expense — charge opérationnelle non liée à une vente précise.
// Exemples : abonnement logiciel, publicité, loyer, frais d'expédition
// généraux, salaires, impôts. Distinct des `fees` d'une commande (qui eux
// sont répartis au prorata des articles comme coût de revient).
// ═════════════════════════════════════════════════════════════════════════════

enum ExpenseCategory {
  subscription,  // Abonnements, logiciels, services
  marketing,     // Publicité, promotions, influenceurs
  shipping,      // Expéditions, logistique générale
  rent,          // Loyer, charges locatives
  utilities,     // Électricité, eau, internet, téléphone
  salaries,      // Salaires, honoraires, primes
  supplies,      // Fournitures bureau, emballages en vrac
  taxes,         // Impôts, taxes, frais administratifs
  other,         // Autre (divers)
}

extension ExpenseCategoryX on ExpenseCategory {
  String get label => switch (this) {
    ExpenseCategory.subscription => 'Abonnement',
    ExpenseCategory.marketing    => 'Publicité',
    ExpenseCategory.shipping     => 'Expédition',
    ExpenseCategory.rent         => 'Loyer',
    ExpenseCategory.utilities    => 'Services',
    ExpenseCategory.salaries     => 'Salaires',
    ExpenseCategory.supplies     => 'Fournitures',
    ExpenseCategory.taxes        => 'Taxes',
    ExpenseCategory.other        => 'Autre',
  };

  IconData get icon => switch (this) {
    ExpenseCategory.subscription => Icons.subscriptions_rounded,
    ExpenseCategory.marketing    => Icons.campaign_rounded,
    ExpenseCategory.shipping     => Icons.local_shipping_rounded,
    ExpenseCategory.rent         => Icons.home_work_rounded,
    ExpenseCategory.utilities    => Icons.bolt_rounded,
    ExpenseCategory.salaries     => Icons.payments_rounded,
    ExpenseCategory.supplies     => Icons.inventory_rounded,
    ExpenseCategory.taxes        => Icons.account_balance_rounded,
    ExpenseCategory.other        => Icons.more_horiz_rounded,
  };

  Color get color => switch (this) {
    ExpenseCategory.subscription => const Color(0xFF3B82F6),
    ExpenseCategory.marketing    => const Color(0xFFEC4899),
    ExpenseCategory.shipping     => const Color(0xFF8B5CF6),
    ExpenseCategory.rent         => const Color(0xFF6366F1),
    ExpenseCategory.utilities    => const Color(0xFFF59E0B),
    ExpenseCategory.salaries     => const Color(0xFF10B981),
    ExpenseCategory.supplies     => const Color(0xFF14B8A6),
    ExpenseCategory.taxes        => const Color(0xFFEF4444),
    ExpenseCategory.other        => const Color(0xFF6B7280),
  };

  static ExpenseCategory fromString(String? s) =>
      ExpenseCategory.values.firstWhere(
        (c) => c.name == s,
        orElse: () => ExpenseCategory.other,
      );
}

class Expense extends Equatable {
  final String         id;
  final String         shopId;
  final double         amount;
  final ExpenseCategory category;
  final String         label;
  final DateTime       paidAt;
  final PaymentMethod  paymentMethod;
  final String?        receiptUrl;
  final String?        notes;
  final String?        createdBy;
  final DateTime       createdAt;

  const Expense({
    required this.id,
    required this.shopId,
    required this.amount,
    required this.category,
    required this.label,
    required this.paidAt,
    this.paymentMethod = PaymentMethod.cash,
    this.receiptUrl,
    this.notes,
    this.createdBy,
    required this.createdAt,
  });

  Expense copyWith({
    double? amount,
    ExpenseCategory? category,
    String? label,
    DateTime? paidAt,
    PaymentMethod? paymentMethod,
    String? receiptUrl,
    bool clearReceiptUrl = false,
    String? notes,
    bool clearNotes = false,
  }) => Expense(
    id:            id,
    shopId:        shopId,
    amount:        amount        ?? this.amount,
    category:      category      ?? this.category,
    label:         label         ?? this.label,
    paidAt:        paidAt        ?? this.paidAt,
    paymentMethod: paymentMethod ?? this.paymentMethod,
    receiptUrl:    clearReceiptUrl ? null : (receiptUrl ?? this.receiptUrl),
    notes:         clearNotes      ? null : (notes      ?? this.notes),
    createdBy:     createdBy,
    createdAt:     createdAt,
  );

  @override
  List<Object?> get props => [id, shopId, amount, category, label, paidAt,
      paymentMethod, receiptUrl, notes];
}
