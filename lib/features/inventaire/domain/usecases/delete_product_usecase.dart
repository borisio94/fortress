import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/database/app_database.dart';
import '../entities/product.dart';

/// Use case : suppression sécurisée d'un produit (hotfix_085).
///
/// Contrat (miroir de la RPC SQL `delete_product`)
/// ───────────────────────────────────────────────
/// 1. Le produit doit exister localement.
/// 2. Motif ≥ 10 caractères.
/// 3. Stock résiduel == 0 (somme sur variants + stock_levels).
/// 4. 0 commande ouverte (scheduled/processing) non-supprimée ne référence
///    le produit ou une de ses variantes.
/// 5. L'utilisateur doit avoir `canDeleteProduct` (vérifié côté UI ; la
///    RPC SQL re-vérifie via `_is_shop_admin`).
///
/// Effets
/// ──────
/// Délègue à `AppDatabase.deleteProduct` qui :
///   • marque `deleted_at / deleted_by / delete_reason / is_active=false /
///     is_visible_web=false` dans Hive,
///   • pousse la RPC `delete_product` (online direct ou enqueue offline),
///   • notifie listeners + invalide cache produits.
///
/// La RPC serveur capture aussi un `archived_snapshot` qui redescend par
/// realtime — utile pour l'écran super-admin.
///
/// Exceptions
/// ──────────
/// Toutes implémentent [DeleteProductException] → le dialog catche
/// l'interface et affiche `message`. Les codes sont alignés sur la RPC
/// SQL pour faciliter la corrélation logs Flutter ↔ logs serveur.
///
/// Note : [ProductNotDeletableException] (existant, défini dans
/// `product.dart`) est levée par `AppDatabase.deleteProduct` quand le
/// stock ou des commandes ouvertes bloquent ; le caller dialog la traite
/// comme une [DeleteProductException] via duck-typing sur `message`.
class DeleteProductUseCase {
  DeleteProductUseCase();

  /// Longueur minimale du motif. Aligné sur la RPC SQL
  /// (`delete_product.length(v_reason) < 10`).
  static const minReasonLength = 10;

  /// Pré-check léger basé sur l'entity en mémoire — utile à l'UI pour
  /// décider d'ouvrir directement le dialog "Bloqué + archiver" plutôt
  /// que le dialog motif si on sait déjà que le produit a du stock
  /// (économise un clic à l'utilisateur). Ne vérifie PAS les commandes
  /// ouvertes ni les stock_levels distincts — c'est `AppDatabase.deleteProduct`
  /// qui fait l'analyse complète et lèvera [ProductNotDeletableException]
  /// avec les vrais compteurs.
  ProductNotDeletableException? peekBlocker(Product product) {
    if (product.totalStock > 0 || product.totalPhysical > 0) {
      return ProductNotDeletableException(
        productName:    product.name,
        totalAvailable: product.totalStock,
        totalPhysical:  product.totalPhysical,
      );
    }
    return null;
  }

  Future<void> call({
    required String productId,
    required String reason,
  }) async {
    final trimmed = reason.trim();
    if (trimmed.length < minReasonLength) {
      throw const MotifSuppressionProduitRequiredException();
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw const PermissionInsuffisanteException();
    }
    // AppDatabase.deleteProduct fait les validations stock + commandes,
    // marque Hive, et push la RPC. Les exceptions remontent telles
    // quelles → le dialog les catch via DeleteProductException.
    await AppDatabase.deleteProduct(productId, reason: trimmed, userId: userId);
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Exceptions — codes lisibles, alignés sur la RPC SQL `delete_product`.
// L'interface `DeleteProductException` regroupe nos exceptions ET la
// `ProductNotDeletableException` existante (qui l'implémente aussi via
// `implements`).
// ══════════════════════════════════════════════════════════════════════════

abstract class DeleteProductException implements Exception {
  String get code;
  String get message;
}

class MotifSuppressionProduitRequiredException implements DeleteProductException {
  const MotifSuppressionProduitRequiredException();
  @override String get code => 'motif_required';
  @override String get message =>
      'Motif obligatoire pour supprimer (10 caractères minimum).';
  @override String toString() => 'MotifSuppressionProduitRequiredException';
}

class PermissionInsuffisanteException implements DeleteProductException {
  const PermissionInsuffisanteException();
  @override String get code => 'permission_insuffisante';
  @override String get message =>
      'Suppression réservée aux administrateurs / propriétaires.';
  @override String toString() => 'PermissionInsuffisanteException';
}
