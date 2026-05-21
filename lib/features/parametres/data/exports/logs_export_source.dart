import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../core/services/export_models.dart';
import '../../../../core/storage/local_storage_service.dart';

/// Type de journal à exporter — sert à la page /exports pour choisir
/// la source (table Supabase + colonnes affichées).
enum LogsSubtype {
  /// `activity_logs` complet — actions tracées par l'app.
  activity,
  /// `stock_movements` — entrées, sorties, ajustements, transferts.
  stockMovements,
  /// `expenses` — charges opérationnelles de la boutique.
  expenses,
  /// Sous-ensemble `activity_logs` filtré aux events RH
  /// (création/modification/suppression d'employés, changement de
  /// rôle, suspension). Pas de table dédiée — c'est un filtre.
  hr,
}

extension LogsSubtypeX on LogsSubtype {
  String get labelFr => switch (this) {
        LogsSubtype.activity       => 'Journal d\'activité',
        LogsSubtype.stockMovements => 'Mouvements de stock',
        LogsSubtype.expenses       => 'Dépenses',
        LogsSubtype.hr             => 'Évènements RH',
      };

  /// Clé utilisée dans le filename de l'export.
  String get filenameKey => switch (this) {
        LogsSubtype.activity       => 'activity',
        LogsSubtype.stockMovements => 'mouvements',
        LogsSubtype.expenses       => 'depenses',
        LogsSubtype.hr             => 'rh',
      };

  /// Header CSV/PDF (5 colonnes max pour rester lisible).
  List<String> get header => switch (this) {
        LogsSubtype.activity => const [
            'Date',
            'Action',
            'Cible',
            'Libellé',
            'Auteur',
          ],
        LogsSubtype.stockMovements => const [
            'Date',
            'Produit/Variante',
            'Quantité',
            'Type',
            'Référence',
          ],
        LogsSubtype.expenses => const [
            'Date',
            'Catégorie',
            'Montant',
            'Libellé',
            'Mode paiement',
          ],
        LogsSubtype.hr => const [
            'Date',
            'Action',
            'Employé',
            'Détail',
            'Auteur',
          ],
      };
}

/// Source de données pour l'export des journaux — fetch Supabase paginé.
///
/// Pourquoi pas Hive : les journaux sont volumineux (10k+ lignes
/// possibles sur une année) et ne sont pas mis en cache complet
/// localement. On va chercher directement la donnée serveur qui est
/// la source de vérité, paginée par tranches de 1000 (cap 5 pages =
/// 5000 lignes max pour rester dans des délais raisonnables web).
/// La RLS Supabase filtre déjà par `_is_shop_member` → un user ne
/// peut JAMAIS récupérer des logs hors de son périmètre, même s'il
/// bidouille les `shop_id` envoyés.
class LogsExportSource {
  const LogsExportSource._();

  static const int _pageSize = 1000;
  /// Cap dur — au-delà, on coupe et on prévient l'utilisateur (peu
  /// probable en pratique : 5000 lignes couvre largement plusieurs
  /// mois d'activité d'une PME).
  static const int _maxRows = 5000;

  static Future<LogsExportResult> collect({
    required ExportScope scope,
    required LogsSubtype subtype,
  }) async {
    final shopIds = _resolveShopIds(scope);
    if (shopIds.isEmpty) {
      return const LogsExportResult(rows: [], truncated: false);
    }
    return switch (subtype) {
      LogsSubtype.activity       => _activityLog(shopIds, hrOnly: false),
      LogsSubtype.hr             => _activityLog(shopIds, hrOnly: true),
      LogsSubtype.stockMovements => _stockMovements(shopIds),
      LogsSubtype.expenses       => _expenses(shopIds),
    };
  }

  // ── Scope → list of shop_ids ───────────────────────────────────

  static List<String> _resolveShopIds(ExportScope scope) {
    return switch (scope) {
      ExportScopeShop(:final shopId) => [shopId],
      ExportScopePartner(:final shopId) => [shopId],
      ExportScopeGlobal() => () {
          final me = LocalStorageService.getCurrentUser();
          if (me == null) return <String>[];
          return LocalStorageService.getShopsForUser(me.id)
              .map((s) => s.id)
              .toList();
        }(),
    };
  }

  // ── Activity / RH ──────────────────────────────────────────────

  static Future<LogsExportResult> _activityLog(
      List<String> shopIds, {required bool hrOnly}) async {
    final db = Supabase.instance.client;
    final all = <Map<String, dynamic>>[];
    bool truncated = false;
    int from = 0;
    while (all.length < _maxRows) {
      final to = from + _pageSize - 1;
      var q = db.from('activity_logs')
          .select('created_at, action, target_type, target_label, '
                  'actor_email, details');
      // .inFilter accepte un seul shop_id côté Supabase ? Oui : `in_`
      // prend une liste. Cf. PostgrestFilterBuilder.
      q = q.inFilter('shop_id', shopIds);
      if (hrOnly) {
        // Le filtre RH : tout ce qui touche un membre (employé) — qu'on
        // identifie par `target_type = 'member'`. Les actions actuellement
        // tracées sont: member_invite, member_create, member_update_role,
        // member_suspend, member_archive, member_delete (cf. ActivityLogService).
        q = q.eq('target_type', 'member');
      }
      final chunk = await q
          .order('created_at', ascending: false)
          .range(from, to);
      final list = List<Map<String, dynamic>>.from(chunk);
      all.addAll(list);
      if (list.length < _pageSize) break;
      from += _pageSize;
    }
    if (all.length >= _maxRows) truncated = true;
    final rows = all.take(_maxRows).map((m) => <Object?>[
          _formatDate(m['created_at'] as String?),
          _actionLabel(m['action'] as String?, hrOnly: hrOnly),
          (m['target_type'] as String?) ?? '',
          (m['target_label'] as String?) ?? '',
          (m['actor_email']  as String?) ?? '',
        ]).toList();
    return LogsExportResult(rows: rows, truncated: truncated);
  }

  // ── Stock movements ───────────────────────────────────────────

  static Future<LogsExportResult> _stockMovements(
      List<String> shopIds) async {
    final db = Supabase.instance.client;
    final all = <Map<String, dynamic>>[];
    int from = 0;
    while (all.length < _maxRows) {
      final chunk = await db.from('stock_movements')
          .select('created_at, type, quantity, reference, notes, '
                  'product_id, variant_id')
          .inFilter('shop_id', shopIds)
          .order('created_at', ascending: false)
          .range(from, from + _pageSize - 1);
      final list = List<Map<String, dynamic>>.from(chunk);
      all.addAll(list);
      if (list.length < _pageSize) break;
      from += _pageSize;
    }
    final truncated = all.length >= _maxRows;
    final rows = all.take(_maxRows).map((m) {
      // On affiche product_id (court 8 chars) — si l'utilisateur veut
      // le nom, il joint avec son catalogue. Évite un 2e fetch.
      final pid = m['product_id'] as String? ?? '';
      final vid = m['variant_id'] as String?;
      final variantLabel = vid != null && vid.isNotEmpty
          ? '${_shortId(pid)}#${_shortId(vid)}'
          : _shortId(pid);
      final qty = (m['quantity'] as num?)?.toInt() ?? 0;
      final qtyLabel = qty > 0 ? '+$qty' : '$qty';
      return <Object?>[
        _formatDate(m['created_at'] as String?),
        variantLabel,
        qtyLabel,
        _stockTypeLabel(m['type'] as String?),
        (m['reference'] as String?) ?? (m['notes'] as String?) ?? '',
      ];
    }).toList();
    return LogsExportResult(rows: rows, truncated: truncated);
  }

  // ── Expenses ──────────────────────────────────────────────────

  static Future<LogsExportResult> _expenses(List<String> shopIds) async {
    final db = Supabase.instance.client;
    final all = <Map<String, dynamic>>[];
    int from = 0;
    while (all.length < _maxRows) {
      final chunk = await db.from('expenses')
          .select('paid_at, category, amount, label, payment_method')
          .inFilter('shop_id', shopIds)
          .order('paid_at', ascending: false)
          .range(from, from + _pageSize - 1);
      final list = List<Map<String, dynamic>>.from(chunk);
      all.addAll(list);
      if (list.length < _pageSize) break;
      from += _pageSize;
    }
    final truncated = all.length >= _maxRows;
    final rows = all.take(_maxRows).map((m) => <Object?>[
          _formatDate(m['paid_at'] as String?),
          _expenseCategoryLabel(m['category'] as String?),
          (m['amount'] as num?)?.toDouble() ?? 0,
          (m['label']  as String?) ?? '',
          _paymentMethodLabel(m['payment_method'] as String?),
        ]).toList();
    return LogsExportResult(rows: rows, truncated: truncated);
  }

  // ── Helpers ───────────────────────────────────────────────────

  static String _formatDate(String? iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final local = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _shortId(String? id) {
    if (id == null || id.isEmpty) return '';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  static String _actionLabel(String? raw, {required bool hrOnly}) {
    if (raw == null) return '';
    // Map les actions RH les plus courantes ; les autres restent telles
    // quelles (avec underscore → espace pour la lisibilité).
    final hrMap = <String, String>{
      'member_invite':       'Invitation employé',
      'member_create':       'Création employé',
      'member_update_role':  'Changement de rôle',
      'member_suspend':      'Suspension',
      'member_archive':      'Archivage',
      'member_delete':       'Suppression',
      'user_login':          'Connexion',
      'user_signup':         'Inscription',
    };
    return hrMap[raw] ?? raw.replaceAll('_', ' ');
  }

  static String _stockTypeLabel(String? key) => switch (key) {
        'entry'           => 'Entrée',
        'sale'            => 'Vente',
        'adjustment'      => 'Ajustement',
        'incident'        => 'Incident',
        'repair_cost'     => 'Réparation',
        'return_supplier' => 'Retour fournisseur',
        'return_client'   => 'Retour client',
        'transfer'        => 'Transfert',
        'scrapped'        => 'Rebut',
        _                 => key ?? '',
      };

  static String _expenseCategoryLabel(String? key) => switch (key) {
        'subscription' => 'Abonnement',
        'marketing'    => 'Marketing',
        'shipping'     => 'Livraison',
        'rent'         => 'Loyer',
        'utilities'    => 'Charges',
        'salaries'     => 'Salaires',
        'supplies'     => 'Fournitures',
        'taxes'        => 'Taxes',
        'other'        => 'Autre',
        _              => key ?? '',
      };

  static String _paymentMethodLabel(String? key) => switch (key) {
        'cash'         => 'Espèces',
        'mobile_money' => 'Mobile Money',
        'mobileMoney'  => 'Mobile Money',
        'card'         => 'Carte',
        'credit'       => 'Crédit',
        _              => key ?? '',
      };
}

/// Résultat d'une collecte logs — porte le flag `truncated` pour que
/// l'UI puisse afficher un avertissement quand on a atteint le cap.
class LogsExportResult {
  final List<List<Object?>> rows;
  final bool truncated;
  const LogsExportResult({required this.rows, required this.truncated});
}
