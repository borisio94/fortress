import 'package:equatable/equatable.dart';

/// Périmètre d'un export — détermine quelles lignes sont collectées
/// avant sérialisation CSV/PDF. Sélectionné par l'utilisateur via le
/// bottom-sheet `ExportScopeSelector` puis transporté dans
/// `ExportConfig.scope` jusqu'au data source de chaque type d'export.
///
/// La RLS Supabase + le pré-filtrage Hive (par membership) garantissent
/// qu'un user ne peut JAMAIS collecter de données hors de son périmètre
/// autorisé, même s'il bidouille le scope envoyé.
sealed class ExportScope extends Equatable {
  const ExportScope();
}

/// Toutes les boutiques accessibles à l'utilisateur (multi-shop owner).
/// Ne fait pas exception au RLS — la collecte itère uniquement les
/// shops du cache `memberships_box`.
class ExportScopeGlobal extends ExportScope {
  const ExportScopeGlobal();
  @override
  List<Object?> get props => const [];
}

/// Une seule boutique. `shopId` validé contre les memberships locales
/// avant la collecte (les routes du shell garantissent déjà ce point).
class ExportScopeShop extends ExportScope {
  final String shopId;
  const ExportScopeShop(this.shopId);
  @override
  List<Object?> get props => [shopId];
}

/// Un dépôt partenaire d'une boutique précise (cf. `StockLocation` type
/// `partner`). Permet par exemple d'exporter UNIQUEMENT le stock confié
/// à ce partenaire pour audit/rapprochement.
class ExportScopePartner extends ExportScope {
  final String shopId;
  final String locationId;
  const ExportScopePartner({
    required this.shopId,
    required this.locationId,
  });
  @override
  List<Object?> get props => [shopId, locationId];
}

/// Format de sortie sélectionné dans le selector.
enum ExportFormat { csv, pdf }

extension ExportFormatX on ExportFormat {
  String get key => switch (this) {
        ExportFormat.csv => 'csv',
        ExportFormat.pdf => 'pdf',
      };
  String get labelFr => switch (this) {
        ExportFormat.csv => 'CSV',
        ExportFormat.pdf => 'PDF',
      };
  String get mimeType => switch (this) {
        ExportFormat.csv => 'text/csv',
        ExportFormat.pdf => 'application/pdf',
      };
  String get extension => switch (this) {
        ExportFormat.csv => 'csv',
        ExportFormat.pdf => 'pdf',
      };
}

/// Type d'export — sert à choisir le data source et à construire le
/// nom de fichier (`fortress_<type>_<scope>_<YYYYMMDD>`).
enum ExportType { products, orders, clients, logs }

extension ExportTypeX on ExportType {
  String get key => switch (this) {
        ExportType.products => 'produits',
        ExportType.orders   => 'commandes',
        ExportType.clients  => 'clients',
        ExportType.logs     => 'logs',
      };
  String get labelFr => switch (this) {
        ExportType.products => 'Produits',
        ExportType.orders   => 'Commandes',
        ExportType.clients  => 'Clients',
        ExportType.logs     => 'Journaux',
      };
}

/// Configuration complète d'un export. Construite par
/// `ExportScopeSelector` puis passée à `ExportService.exportToCsv` /
/// `exportToPdf`. Le `filenameBase` est calculé sans extension —
/// l'extension est ajoutée par `ExportService` selon le format.
class ExportConfig extends Equatable {
  final ExportType   type;
  final ExportScope  scope;
  final ExportFormat format;
  /// Libellé scope humain pour l'en-tête PDF (ex: « Globale »,
  /// « Boutique : Fortress Centre », « Partenaire : Dépôt Bonapriso »).
  /// Construit par le selector au moment du choix — on évite ainsi
  /// au data source de connaître les noms de shop/partenaire.
  final String       scopeLabel;
  /// Nom de boutique pour l'en-tête PDF si scope == shop/partner.
  /// `null` pour scope global (l'en-tête affichera alors le nom de
  /// l'opérateur ou rien).
  final String?      shopName;

  const ExportConfig({
    required this.type,
    required this.scope,
    required this.format,
    required this.scopeLabel,
    this.shopName,
  });

  /// `fortress_produits_shop_<id>_20260521`. La date est UTC pour rester
  /// déterministe entre devices (un user qui exporte depuis 2 fuseaux
  /// n'aura pas 2 noms différents pour la même base de données).
  String filenameBase(DateTime now) {
    final d = now.toUtc();
    final ymd = '${d.year.toString().padLeft(4, '0')}'
                '${d.month.toString().padLeft(2, '0')}'
                '${d.day.toString().padLeft(2, '0')}';
    final scopeKey = switch (scope) {
      ExportScopeGlobal()        => 'global',
      ExportScopeShop(:final shopId) => 'shop_$shopId',
      ExportScopePartner(:final locationId) => 'partner_$locationId',
    };
    return 'fortress_${type.key}_${scopeKey}_$ymd';
  }

  @override
  List<Object?> get props => [type, scope, format, scopeLabel, shopName];
}
