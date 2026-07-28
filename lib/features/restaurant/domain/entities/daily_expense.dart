import 'package:flutter/material.dart';

import '../../../../core/storage/schema_migrator.dart';

/// Catégories de dépense quotidienne — alignées sur le CHECK SQL de
/// `daily_expenses.category` (hotfix_149).
enum ExpenseKind {
  achatMarche('achat_marche', 'Achat marché', Icons.shopping_basket_outlined),
  electricite('electricite', 'Électricité', Icons.bolt_outlined),
  gaz('gaz', 'Gaz', Icons.local_fire_department_outlined),
  eau('eau', 'Eau', Icons.water_drop_outlined),
  transport('transport', 'Transport', Icons.local_taxi_outlined),
  entretien('entretien', 'Entretien', Icons.cleaning_services_outlined),
  personnel('personnel', 'Extras personnel', Icons.person_add_alt_outlined),
  autre('autre', 'Autre', Icons.more_horiz_rounded);

  const ExpenseKind(this.key, this.label, this.icon);

  final String key;
  final String label;
  final IconData icon;

  /// L'achat de matières premières EST le food cost réel : c'est la seule
  /// catégorie comparable au coût matières théorique des fiches recettes.
  bool get isFoodCost => this == ExpenseKind.achatMarche;

  static ExpenseKind fromKey(String? k) {
    final v = (k ?? '').trim().toLowerCase();
    for (final e in ExpenseKind.values) {
      if (e.key == v) return e;
    }
    return ExpenseKind.autre;
  }
}

/// Une dépense du jour (Lot E — hotfix_149).
///
/// Distincte d'une charge fixe : celle-ci est un FAIT (« 12 000 F de poisson ce
/// matin »), pas une échéance qu'on anticipe.
class DailyExpense {
  final String id;
  final String shopId;
  final String description;
  final int amount;

  /// Clé de catégorie (cf. [ExpenseKind]).
  final String category;

  /// Qui a payé : au restaurant, l'argent du marché part souvent de la poche
  /// d'un employé qu'il faut rembourser.
  final String? paidBy;

  /// Payé en espèces ? Décide si la dépense sort du TIROIR, et donc si elle
  /// est déduite du total attendu à la clôture de caisse.
  final bool isCash;

  final DateTime expenseDate;
  final DateTime createdAt;

  const DailyExpense({
    required this.id,
    required this.shopId,
    required this.description,
    required this.expenseDate,
    required this.createdAt,
    this.amount = 0,
    this.category = 'autre',
    this.paidBy,
    this.isCash = true,
  });

  ExpenseKind get kind => ExpenseKind.fromKey(category);

  bool get isFoodCost => kind.isFoodCost;

  /// Clé `yyyy-MM-dd` d'une date (stockage DATE sans heure).
  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  DailyExpense copyWith({
    String? description,
    int? amount,
    String? category,
    String? paidBy,
    bool? isCash,
    DateTime? expenseDate,
  }) =>
      DailyExpense(
        id: id,
        shopId: shopId,
        createdAt: createdAt,
        description: description ?? this.description,
        amount: amount ?? this.amount,
        category: category ?? this.category,
        paidBy: paidBy ?? this.paidBy,
        isCash: isCash ?? this.isCash,
        expenseDate: expenseDate ?? this.expenseDate,
      );

  static const int currentSchemaVersion = 1;
  static const SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion,
    steps: {},
  );

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id': id,
        'shop_id': shopId,
        'description': description,
        'amount': amount,
        'category': category,
        'paid_by': paidBy,
        'is_cash': isCash,
        'expense_date': dayKey(expenseDate),
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  factory DailyExpense.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return DailyExpense(
      id: m['id'].toString(),
      shopId: m['shop_id'].toString(),
      description: (m['description'] ?? '').toString(),
      amount: (m['amount'] as num?)?.toInt() ?? 0,
      // Normalisé via l'enum : une valeur hors CHECK ferait rejeter l'upsert
      // par Postgres et l'op serait droppée après dix essais, sans bruit.
      category: ExpenseKind.fromKey(m['category']?.toString()).key,
      paidBy: _nullIfEmpty(m['paid_by']),
      isCash: m['is_cash'] as bool? ?? true,
      expenseDate:
          DateTime.tryParse(m['expense_date']?.toString() ?? '') ??
              DateTime.now(),
      createdAt: m['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(m['created_at'].toString())?.toLocal() ??
              DateTime.now()),
    );
  }

  static String? _nullIfEmpty(dynamic v) {
    final s = v?.toString().trim() ?? '';
    return s.isEmpty ? null : s;
  }
}
