import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/activity_actions.dart';

/// Garantit qu'AUCUNE action de la boutique ne « passe entre les filières » :
/// chaque action émise par l'app via ActivityLogService.log(action: ...) doit
/// avoir une catégorie connue, sinon elle serait invisible dans tous les
/// filtres de l'historique sauf « Tous ».
///
/// `emitted` = liste exhaustive des actions réellement émises dans le code
/// (auditée). Toute nouvelle action ajoutée dans l'app doit l'être ici ET
/// dans ActivityActions — ce test sert de garde-fou.
void main() {
  const emitted = <String>[
    // ── Auth / sécurité ──
    'user_login', 'user_signup', 'super_admin_password_reset',
    // ── Boutique ──
    'shop_created', 'shop_updated', 'shop_deleted', 'shop_reset_keep_products',
    // ── Produits / métadonnées ──
    'product_created', 'product_updated', 'product_deleted', 'product_archived',
    'product_auto_merged', 'product_copied_out', 'product_copied_in',
    'stock_updated',
    'category_created', 'category_updated', 'category_deleted',
    'brand_created', 'brand_updated', 'brand_deleted',
    'unit_created', 'unit_updated', 'unit_deleted',
    'supplier_created', 'supplier_deleted', 'reception_validated',
    // ── Stock ──
    'stock_arrival', 'stock_incident', 'stock_adjusted',
    'stock_transfer_out', 'stock_transfer_in',
    'stock_audit_run', 'stock_audit_drift', 'stock_audit_corrected',
    // ── Ventes / commandes ──
    'sale_completed', 'sale_deleted',
    'order_cancelled', 'order_refunded', 'order_delivered', 'order_rescheduled',
    'order_status_changed', 'acompte_recorded',
    'order_cancelled_by_client_from_alert',
    // ── Service restaurant sous PIN gérant (Lot A) ──
    'round_cancelled', 'bill_discounted', 'cash_closure_x', 'cash_closure_z',
    // ── Clients / dépenses ──
    'client_created', 'client_updated', 'client_deleted',
    'expense_created', 'expense_updated', 'expense_deleted',
    // ── Membres / comptes / abonnements ──
    'member_added', 'member_role_changed', 'member_removed',
    'member_suspended', 'member_reactivated',
    'user_blocked', 'user_unblocked',
    'subscription_activated', 'subscription_cancelled',
    'plan_created', 'plan_updated', 'plan_deleted', 'broadcast_sent',
  ];

  group('ActivityActions — aucune action ne passe entre les filtres', () {
    test('toute action émise a une catégorie valide (jamais "other")', () {
      final uncategorized = [
        for (final a in emitted)
          if (ActivityActions.categoryOf(a) == ActivityCategory.other) a,
      ];
      expect(uncategorized, isEmpty,
          reason: 'Actions qui tomberaient hors des filtres : $uncategorized');
    });

    test('chaque action émise tombe dans un filtre connu', () {
      for (final a in emitted) {
        expect(ActivityCategory.all.contains(ActivityActions.categoryOf(a)),
            isTrue,
            reason: 'Catégorie hors filtres pour "$a"');
      }
    });

    test('catalogue cohérent : toutes les actions connues sont catégorisées', () {
      for (final a in ActivityActions.known) {
        expect(ActivityCategory.all.contains(ActivityActions.categoryOf(a)),
            isTrue,
            reason: '"$a" a une catégorie hors filtres');
      }
    });

    test('toute action émise est cataloguée (isKnown)', () {
      final missing = [for (final a in emitted) if (!ActivityActions.isKnown(a)) a];
      expect(missing, isEmpty,
          reason: 'Actions émises absentes du catalogue : $missing');
    });

    test('action inconnue → "other" (filet de sécurité)', () {
      expect(ActivityActions.categoryOf('action_inexistante_xyz'),
          ActivityCategory.other);
      expect(ActivityActions.isKnown('action_inexistante_xyz'), isFalse);
    });
  });
}
