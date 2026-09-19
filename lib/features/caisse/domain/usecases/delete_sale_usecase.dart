import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/activity_log_service.dart';
import '../../data/repositories/sale_local_datasource.dart';
import '../entities/sale.dart';

/// Use case : suppression sécurisée d'une commande (hotfix_084).
///
/// Contrat
/// ───────
/// 1. La commande doit exister localement.
/// 2. Statut ∈ {scheduled, processing, refused, cancelled}.
/// 3. `amount_paid == 0` (aucun encaissement boutique ou partenaire).
/// 4. Motif ≥ 10 caractères.
///
/// Toute violation lève une exception typée avec un `code` lisible que
/// le `CaisseBloc` mappe en message FR pour l'utilisateur. Le contrat est
/// dupliqué côté serveur dans la RPC `delete_sale` — double verrou :
/// le client filtre l'UI, le serveur refuse même si l'UI est contournée.
///
/// Effets
/// ──────
/// Délègue à `SaleLocalDatasource.softDeleteOrder` :
///   • marque `deleted_at / deleted_by / delete_reason` dans Hive,
///   • pousse à Supabase via la RPC `delete_sale` (online direct ou
///     enqueue offline),
///   • notifie les listeners + recompute métriques client,
///   • journalise un `activity_log` local (le serveur en émet un second
///     côté SQL, mais le local est utile pour l'audit offline).
class DeleteSaleUseCase {
  final SaleLocalDatasource _ds;
  DeleteSaleUseCase({SaleLocalDatasource? datasource})
      : _ds = datasource ?? SaleLocalDatasource();

  /// Statuts qui autorisent la suppression (cohérent avec la RPC SQL —
  /// cf. hotfix_117 qui ajoute `cancelled`).
  static const allowedStatuses = <SaleStatus>{
    SaleStatus.scheduled,
    // `processing` (En cours) VOLONTAIREMENT EXCLU : son stock est déjà sorti
    // des disponibles (réservé à l'envoi). Autoriser sa suppression directe =
    // risque de perte sèche de stock. Il faut d'abord ANNULER la commande (ce
    // qui restitue le stock), puis la commande annulée devient supprimable.
    // Retirer ce statut MASQUE aussi le bouton Supprimer (il teste ce set).
    SaleStatus.refused,
    SaleStatus.cancelled,
  };

  /// Longueur minimale du motif. Doit RESTER alignée avec la RPC SQL
  /// (cf. `delete_sale.length(v_reason) < 10`).
  static const minReasonLength = 10;

  Future<void> call({
    required String orderId,
    required String reason,
  }) async {
    final trimmedReason = reason.trim();

    // ── 1. Motif requis (vérification locale avant tout). ────────────────
    if (trimmedReason.length < minReasonLength) {
      throw const MotifSuppressionRequiredException();
    }

    // ── 2. Lecture commande (inclut les soft-deleted pour détecter le
    //       cas idempotent — un 2ᵉ appel ne doit pas throw). ──────────────
    final sale = _ds.getOrderById(orderId, includeDeleted: true);
    if (sale == null) {
      throw const SaleNotFoundException();
    }

    // Idempotence locale : déjà supprimée → no-op silencieux.
    if (sale.isDeleted) return;

    // ── 3. Garde-fou statut. ─────────────────────────────────────────────
    if (!allowedStatuses.contains(sale.status)) {
      throw SuppressionStatutInvalideException(sale.status);
    }

    // ── 4. Garde-fou paiement. ───────────────────────────────────────────
    if (sale.amountPaid > 0) {
      throw SuppressionCommandePayeeException(sale.amountPaid);
    }

    // ── 5. Auteur (auth.users.id). Le caller a déjà validé qu'une
    //       session est active via la permission `canDeleteOrder` ; on
    //       garde une garde défensive en cas de session perdue. ──────────
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) {
      throw const SaleNotFoundException();
    }

    // ── 6. Application — Hive + RPC. La datasource gère elle-même la
    //       file offline en cas d'absence de réseau. Les erreurs métier
    //       serveur (P0001) remontent via bgSoftDeleteSale et sont
    //       considérées comme une divergence Hive↔SQL — on les laisse
    //       remonter pour que le bloc affiche un message.
    await _ds.softDeleteOrder(
      orderId,
      reason: trimmedReason,
      userId: userId,
    );

    // ── 7. Trace activity_log local. La RPC serveur en émet aussi une
    //       (déduplication par `created_at` côté liste — best-effort).
    await ActivityLogService.log(
      action:      'sale_deleted',
      targetType:  'sale',
      targetId:    orderId,
      targetLabel: sale.clientName,
      shopId:      sale.shopId,
      details: {
        'reason':        trimmedReason,
        'status_before': sale.status.name,
        'amount_paid':   sale.amountPaid,
      },
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════
// Exceptions — codes lisibles, alignés sur la RPC SQL `delete_sale`.
// Chaque exception expose :
//   • `code`    : identifiant machine (pour tests / logs / banner).
//   • `message` : libellé FR à afficher tel quel en SnackBar / dialog.
// Le dialog UI catche l'interface `DeleteSaleException` pour rester
// agnostique du type concret.
// ══════════════════════════════════════════════════════════════════════════

abstract class DeleteSaleException implements Exception {
  String get code;
  String get message;
}

class MotifSuppressionRequiredException implements DeleteSaleException {
  const MotifSuppressionRequiredException();
  @override String get code => 'motif_required';
  @override String get message =>
      'Motif obligatoire pour supprimer (10 caractères minimum).';
  @override String toString() => 'MotifSuppressionRequiredException';
}

class SuppressionStatutInvalideException implements DeleteSaleException {
  final SaleStatus status;
  const SuppressionStatutInvalideException(this.status);
  @override String get code => 'suppression_statut_invalide';
  @override String get message =>
      'Suppression refusée : statut « ${status.label} » non éligible. '
      'Seules les commandes programmées, annulées ou refusées peuvent être '
      'supprimées. Pour une commande en cours, annulez-la d\'abord '
      '(le stock est alors restitué).';
  @override String toString() => 'SuppressionStatutInvalideException($status)';
}

class SuppressionCommandePayeeException implements DeleteSaleException {
  final double amountPaid;
  const SuppressionCommandePayeeException(this.amountPaid);
  @override String get code => 'suppression_commande_payee';
  @override String get message =>
      'Suppression refusée : commande encaissée à hauteur de '
      '${amountPaid.toStringAsFixed(0)}. Rembourse le client avant de '
      'supprimer.';
  @override String toString() =>
      'SuppressionCommandePayeeException($amountPaid)';
}

class SaleNotFoundException implements DeleteSaleException {
  const SaleNotFoundException();
  @override String get code => 'sale_not_found';
  @override String get message => 'Commande introuvable ou session expirée.';
  @override String toString() => 'SaleNotFoundException';
}
