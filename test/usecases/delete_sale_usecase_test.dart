// Tests unitaires du DeleteSaleUseCase (hotfix_084).
//
// Stratégie : on injecte un `SaleLocalDatasource` falsifié via subclass
// qui override `getOrderById` (lookup en mémoire) — aucune initialisation
// Hive nécessaire. On couvre tous les cas qui throw AVANT le lookup
// Supabase auth.uid() (motif, statut, paiement, sale_not_found,
// idempotence), c'est-à-dire l'intégralité du contrat public du use case.
//
// Le chemin success → push RPC est testable seulement via tests
// d'intégration (Hive + Supabase mocké) — hors scope ici.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/data/repositories/sale_local_datasource.dart';
import 'package:fortress/features/caisse/domain/entities/sale.dart';
import 'package:fortress/features/caisse/domain/usecases/delete_sale_usecase.dart';

/// Datasource en mémoire — n'appelle JAMAIS Hive. Sert à isoler
/// l'unité testée (`DeleteSaleUseCase`) du stockage local réel.
class _FakeSaleDatasource extends SaleLocalDatasource {
  final Map<String, Sale> store;
  _FakeSaleDatasource(this.store);

  @override
  Sale? getOrderById(String orderId, {bool includeDeleted = false}) {
    final sale = store[orderId];
    if (sale == null) return null;
    if (!includeDeleted && sale.isDeleted) return null;
    return sale;
  }

  // Le use case appelle `softDeleteOrder` après validation. Pour les tests
  // qui throw AVANT, cette méthode n'est jamais atteinte. Pour les tests
  // d'idempotence (sale déjà supprimée), le use case return AVANT
  // d'appeler softDeleteOrder. On override quand même pour éviter tout
  // accès Hive si la couverture s'étend plus tard.
  @override
  Future<void> softDeleteOrder(String orderId, {
    required String reason,
    required String userId,
  }) async {
    throw UnimplementedError(
        'softDeleteOrder ne devrait pas être appelé dans ces tests — '
        'tous les chemins testés throw avant.');
  }
}

Sale _sale({
  String id = 'sale_1',
  SaleStatus status = SaleStatus.scheduled,
  double amountPaid = 0,
  DateTime? deletedAt,
}) =>
    Sale(
      id:        id,
      shopId:    'shop_test',
      items:     const [],
      paymentMethod: PaymentMethod.cash,
      status:    status,
      amountPaid: amountPaid,
      createdAt: DateTime(2026, 5, 20),
      deletedAt: deletedAt,
    );

void main() {
  group('DeleteSaleUseCase — validations préalables', () {
    test('throws MotifSuppressionRequiredException si motif < 10 chars',
        () async {
      final ds = _FakeSaleDatasource({});
      final useCase = DeleteSaleUseCase(datasource: ds);
      // Motif < 10 → throw AVANT toute lecture (donc store vide ok).
      await expectLater(
        useCase.call(orderId: 'sale_x', reason: 'court'),
        throwsA(isA<MotifSuppressionRequiredException>()),
      );
    });

    test('throws aussi pour un motif vide ou whitespace', () async {
      final useCase = DeleteSaleUseCase(datasource: _FakeSaleDatasource({}));
      await expectLater(
        useCase.call(orderId: 'sale_x', reason: '         '),
        throwsA(isA<MotifSuppressionRequiredException>()),
      );
    });

    test('throws SaleNotFoundException si orderId inexistant', () async {
      final useCase = DeleteSaleUseCase(datasource: _FakeSaleDatasource({}));
      await expectLater(
        useCase.call(
            orderId: 'absent',
            reason:  'Motif valide >10 caractères ici.'),
        throwsA(isA<SaleNotFoundException>()),
      );
    });

    test('idempotent : sale déjà supprimée → no-op silencieux', () async {
      final ds = _FakeSaleDatasource({
        'sale_1': _sale(
            id: 'sale_1',
            status: SaleStatus.scheduled,
            deletedAt: DateTime(2026, 5, 19)),
      });
      final useCase = DeleteSaleUseCase(datasource: ds);
      // Pas de throw, pas d'appel à softDeleteOrder (qui throw
      // UnimplementedError dans le fake) → succès silencieux.
      await useCase.call(
          orderId: 'sale_1',
          reason:  'Motif valide >10 caractères.');
    });

    test('throws SuppressionStatutInvalideException si statut completed',
        () async {
      final ds = _FakeSaleDatasource({
        'sale_1': _sale(status: SaleStatus.completed),
      });
      final useCase = DeleteSaleUseCase(datasource: ds);
      await expectLater(
        useCase.call(
            orderId: 'sale_1',
            reason:  'Motif valide >10 caractères.'),
        throwsA(isA<SuppressionStatutInvalideException>()),
      );
    });

    test('cancelled est désormais éligible à la suppression (hotfix_117)',
        () {
      // La demande produit autorise la suppression des commandes annulées
      // (en plus de programmée/en cours/refusée). cancelled n'est donc plus
      // dans les statuts refusés.
      expect(DeleteSaleUseCase.allowedStatuses,
          contains(SaleStatus.cancelled));
    });

    test('throws SuppressionCommandePayeeException si amountPaid > 0',
        () async {
      final ds = _FakeSaleDatasource({
        'sale_1': _sale(
            status: SaleStatus.scheduled, amountPaid: 5000),
      });
      final useCase = DeleteSaleUseCase(datasource: ds);
      await expectLater(
        useCase.call(
            orderId: 'sale_1',
            reason:  'Motif valide >10 caractères.'),
        throwsA(isA<SuppressionCommandePayeeException>()),
      );
    });

    test('autorise les 4 statuts éligibles : scheduled, processing, refused, '
        'cancelled', () {
      expect(DeleteSaleUseCase.allowedStatuses,
          {SaleStatus.scheduled,
           SaleStatus.processing,
           SaleStatus.refused,
           SaleStatus.cancelled});
    });
  });

  group('DeleteSaleUseCase — contrat des exceptions', () {
    test('MotifSuppressionRequiredException : code + message', () {
      const e = MotifSuppressionRequiredException();
      expect(e.code, 'motif_required');
      expect(e.message, contains('10 caractères'));
      expect(e, isA<DeleteSaleException>());
    });

    test('SaleNotFoundException : code + message', () {
      const e = SaleNotFoundException();
      expect(e.code, 'sale_not_found');
      expect(e.message, isNotEmpty);
      expect(e, isA<DeleteSaleException>());
    });

    test('SuppressionStatutInvalideException : code + status repris', () {
      const e = SuppressionStatutInvalideException(SaleStatus.completed);
      expect(e.code, 'suppression_statut_invalide');
      expect(e.message, contains('Complétée'));
      expect(e.status, SaleStatus.completed);
      expect(e, isA<DeleteSaleException>());
    });

    test('SuppressionCommandePayeeException : code + montant dans message',
        () {
      const e = SuppressionCommandePayeeException(5000);
      expect(e.code, 'suppression_commande_payee');
      expect(e.message, contains('5000'));
      expect(e.amountPaid, 5000);
      expect(e, isA<DeleteSaleException>());
    });

    test('minReasonLength est aligné avec la RPC SQL (>= 10)', () {
      expect(DeleteSaleUseCase.minReasonLength, 10);
    });
  });
}
