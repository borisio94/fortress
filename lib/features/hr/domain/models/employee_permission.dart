import 'member_role.dart';

// ─── EmployeePermission + EmployeeStatus ───────────────────────────────────
//
// Source de vérité côté Dart pour les autorisations granulaires accordées
// aux employés. Les `key` correspondent exactement aux strings stockées
// dans la colonne `shop_memberships.permissions` (JSONB) côté SQL —
// cf. supabase/hotfix_018_employees.sql.
// ───────────────────────────────────────────────────────────────────────────

/// Tier d'accès accordé à un employé. La key est utilisée dans le JSONB
/// Supabase et dans les caches Hive locaux.
enum EmployeePermission {
  // ── Inventaire ───────────────────────────────────────────────────────────
  inventoryView,
  inventoryWrite,
  inventoryDelete,
  inventoryStock,
  /// Exporter le catalogue produits (CSV/PDF). Par défaut admin/owner ;
  /// utilisateur requiert un grant explicite. Vu comme "donnée
  /// sensible" car expose le prix d'achat et l'inventaire complet.
  inventoryExport,

  // ── Caisse / Ventes ──────────────────────────────────────────────────────
  caisseAccess,
  caisseSell,
  caisseEditOrders,
  caisseScheduled,
  /// Voir TOUTES les commandes de la boutique. Sans cette permission, un
  /// employé ne voit que ses propres commandes (createdByUserId == self) +
  /// celles déjà finalisées (status == completed = validées par un supérieur).
  caisseViewAllOrders,
  /// Exporter les commandes (CSV/PDF). Donnée sensible : expose le CA,
  /// la liste des clients, les statuts. Admin/owner par défaut ;
  /// employé requiert un grant explicite.
  caisseExport,

  // ── Clients (CRM) ────────────────────────────────────────────────────────
  crmView,
  crmWrite,
  crmDelete,
  /// Exporter le carnet d'adresses CRM (CSV). Donnée RGPD/sensible :
  /// liste complète des clients + leur valeur. Admin/owner par défaut.
  crmExport,

  // ── Finances ─────────────────────────────────────────────────────────────
  financeView,
  financeExpenses,
  financeExport,

  // ── Boutique ─────────────────────────────────────────────────────────────
  shopSettings,
  shopLocations,
  shopActivity,

  // ── Ventes spéciales (hotfix_024) ───────────────────────────────────────
  /// Annuler une vente déjà encaissée (refund partiel/total).
  salesCancel,
  /// Appliquer une remise hors barème sur une vente.
  salesDiscount,

  // ── Livraison (hotfix_049) ───────────────────────────────────────────────
  /// Transférer une commande "scheduled" à un livreur via WhatsApp.
  /// Owner + admin par défaut ; user requiert un grant explicite.
  deliveryWhatsApp,

  // ── Membres (hotfix_024) ────────────────────────────────────────────────
  /// Inviter un nouveau membre (= créer un employé via RH).
  membersInvite,

  // ── Réservées au propriétaire (hotfix_024) ──────────────────────────────
  /// Supprimer la boutique. RÉSERVÉ AU OWNER. Voir [requiresOwnerApproval].
  shopDelete,
  /// Retirer un admin de la boutique. RÉSERVÉ AU OWNER.
  adminRemove,
  /// Créer une nouvelle boutique. Par défaut owner uniquement. Le propriétaire
  /// peut explicitement déléguer cette permission à un admin (ex: assistant
  /// qui ouvre une succursale). Jamais accordée à un user.
  shopCreate,
  /// Effectuer les "modifications profondes" sur la boutique : reset, purge
  /// logs, supprimer admins, supprimer la boutique. Une boutique ne peut
  /// avoir qu'UN SEUL admin avec cette permission (unicité enforce côté
  /// Flutter au moment de l'enregistrement + trigger SQL en migration 014).
  /// Désigné explicitement par le propriétaire ; jamais accordé par défaut.
  shopFullEdit,
}

/// Catégorie d'affichage pour le formulaire de création/édition d'employé
/// (cases à cocher organisées en sections).
enum EmployeePermissionGroup {
  inventory,
  caisse,
  crm,
  finance,
  shop,
}

extension EmployeePermissionX on EmployeePermission {
  /// Clé canonique stockée en base (ex: 'inventory.view').
  String get key => switch (this) {
    EmployeePermission.inventoryView    => 'inventory.view',
    EmployeePermission.inventoryWrite   => 'inventory.write',
    EmployeePermission.inventoryDelete  => 'inventory.delete',
    EmployeePermission.inventoryStock   => 'inventory.stock',
    EmployeePermission.inventoryExport  => 'inventory.export',
    EmployeePermission.caisseAccess     => 'caisse.access',
    EmployeePermission.caisseSell       => 'caisse.sell',
    EmployeePermission.caisseEditOrders => 'caisse.edit_orders',
    EmployeePermission.caisseScheduled  => 'caisse.scheduled',
    EmployeePermission.caisseViewAllOrders => 'caisse.view_all_orders',
    EmployeePermission.caisseExport     => 'caisse.export',
    EmployeePermission.crmView          => 'crm.view',
    EmployeePermission.crmWrite         => 'crm.write',
    EmployeePermission.crmDelete        => 'crm.delete',
    EmployeePermission.crmExport        => 'crm.export',
    EmployeePermission.financeView      => 'finance.view',
    EmployeePermission.financeExpenses  => 'finance.expenses',
    EmployeePermission.financeExport    => 'finance.export',
    EmployeePermission.shopSettings     => 'shop.settings',
    EmployeePermission.shopLocations    => 'shop.locations',
    EmployeePermission.shopActivity     => 'shop.activity',
    EmployeePermission.salesCancel      => 'sales.cancel',
    EmployeePermission.salesDiscount    => 'sales.discount',
    EmployeePermission.deliveryWhatsApp => 'delivery.send_whatsapp',
    EmployeePermission.membersInvite    => 'members.invite',
    EmployeePermission.shopDelete       => 'shop.delete',
    EmployeePermission.adminRemove      => 'admin.remove',
    EmployeePermission.shopCreate       => 'shop.create',
    EmployeePermission.shopFullEdit     => 'shop.full_edit',
  };

  /// Groupe d'affichage pour le formulaire RH.
  EmployeePermissionGroup get group => switch (this) {
    EmployeePermission.inventoryView    ||
    EmployeePermission.inventoryWrite   ||
    EmployeePermission.inventoryDelete  ||
    EmployeePermission.inventoryStock   ||
    EmployeePermission.inventoryExport  => EmployeePermissionGroup.inventory,
    EmployeePermission.caisseAccess     ||
    EmployeePermission.caisseSell       ||
    EmployeePermission.caisseEditOrders ||
    EmployeePermission.caisseScheduled  ||
    EmployeePermission.caisseViewAllOrders ||
    EmployeePermission.caisseExport     ||
    EmployeePermission.salesCancel      ||
    EmployeePermission.salesDiscount    ||
    EmployeePermission.deliveryWhatsApp => EmployeePermissionGroup.caisse,
    EmployeePermission.crmView          ||
    EmployeePermission.crmWrite         ||
    EmployeePermission.crmDelete        ||
    EmployeePermission.crmExport        => EmployeePermissionGroup.crm,
    EmployeePermission.financeView      ||
    EmployeePermission.financeExpenses  ||
    EmployeePermission.financeExport    => EmployeePermissionGroup.finance,
    EmployeePermission.shopSettings     ||
    EmployeePermission.shopLocations    ||
    EmployeePermission.shopActivity     ||
    EmployeePermission.membersInvite    ||
    EmployeePermission.shopDelete       ||
    EmployeePermission.adminRemove      ||
    EmployeePermission.shopCreate       ||
    EmployeePermission.shopFullEdit     => EmployeePermissionGroup.shop,
  };

  /// True si la permission est réservée au propriétaire et nécessite une
  /// approbation explicite (cf. spec hotfix_024). Ces permissions ne sont
  /// jamais accordées à un admin par les presets — mais le propriétaire
  /// peut les attribuer manuellement à un admin précis (ex: `shopCreate`
  /// pour un assistant qui ouvre une succursale).
  bool get isOwnerOnly =>
      this == EmployeePermission.shopDelete ||
      this == EmployeePermission.adminRemove ||
      this == EmployeePermission.shopCreate ||
      this == EmployeePermission.shopFullEdit;

  /// Conversion inverse string → enum. Retourne null si inconnu (les clés
  /// stockées en base peuvent évoluer plus vite que le code Dart).
  static EmployeePermission? fromKey(String s) {
    for (final p in EmployeePermission.values) {
      if (p.key == s) return p;
    }
    return null;
  }
}

/// Permissions effectives d'un membre dans une boutique, sous forme de
/// **grants** et **denies** explicites (en plus du rôle de base).
///
/// Format JSONB stocké en SQL (`shop_memberships.permissions`) :
///   - clé positive : `"finances.view"` → ajoute la permission au-dessus
///     du rôle de base.
///   - clé `deny:` : `"deny:sales.discount"` → retire la permission même
///     si le rôle de base la donnerait par défaut.
///
/// L'évaluation finale dans [AppPermissions._grain] :
///   1. Owner → toujours `true` (bypass total).
///   2. Permission dans [denies] → `false` (deny gagne).
///   3. Permission dans [grants] → `true`.
///   4. Sinon → fallback sur le rôle de base (legacy).
class MemberPermissions {
  final Set<EmployeePermission> grants;
  final Set<EmployeePermission> denies;

  const MemberPermissions({
    this.grants = const {},
    this.denies = const {},
  });

  /// Set vide (équivalent "rien de spécifique" : utilise le défaut du rôle).
  static const empty = MemberPermissions();

  /// Parse une liste JSONB ["perm", "deny:perm"] en grants/denies.
  factory MemberPermissions.fromList(List<dynamic> raw) {
    final grants = <EmployeePermission>{};
    final denies = <EmployeePermission>{};
    for (final entry in raw) {
      if (entry is! String) continue;
      if (entry.startsWith('deny:')) {
        final perm = EmployeePermissionX.fromKey(entry.substring(5));
        if (perm != null) denies.add(perm);
      } else {
        final perm = EmployeePermissionX.fromKey(entry);
        if (perm != null) grants.add(perm);
      }
    }
    return MemberPermissions(grants: grants, denies: denies);
  }

  /// Sérialisation inverse : retourne la liste JSONB à stocker.
  List<String> toList() => [
        ...grants.map((p) => p.key),
        ...denies.map((p) => 'deny:${p.key}'),
      ];

  bool get isEmpty => grants.isEmpty && denies.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

/// Statut d'un employé dans une boutique. Les chaînes correspondent à la
/// contrainte CHECK SQL `shop_memberships.status`.
enum EmployeeStatus {
  active,
  suspended,
  archived,
}

extension EmployeeStatusX on EmployeeStatus {
  String get key => switch (this) {
    EmployeeStatus.active    => 'active',
    EmployeeStatus.suspended => 'suspended',
    EmployeeStatus.archived  => 'archived',
  };

  static EmployeeStatus fromString(String? s) {
    switch ((s ?? '').toLowerCase()) {
      case 'suspended': return EmployeeStatus.suspended;
      case 'archived':  return EmployeeStatus.archived;
      default:          return EmployeeStatus.active;
    }
  }
}

// `EmployeeRole` retiré (hotfix_024) — remplacé par `MemberRole` canonique
// dans member_role.dart (owner | admin | user). Tous les call sites doivent
// importer `MemberRole` directement.

/// Permissions accordées **par défaut** à un rôle (sans grants/denies).
/// Aligné sur les UPDATEs du hotfix_024 qui backfill les memberships
/// existantes lors de la migration de rôles.
///
/// - `owner` : toutes les permissions — `EmployeePermission.values`, 29 au
///   25/09/2026 (bypass total dans `_grain`).
///   Cette liste est gardée pour cohérence mais n'est jamais consultée
///   en pratique pour un owner.
/// - `admin` : tout sauf les permissions réservées owner (`isOwnerOnly` :
///   `shopDelete`, `adminRemove`, `shopCreate`, `shopFullEdit`).
/// - `user`  : 4 permissions de base (consulter inventaire + encaisser
///   + voir clients).
Set<EmployeePermission> defaultPermissionsForRole(MemberRole role) {
  switch (role) {
    case MemberRole.owner:
      return EmployeePermission.values.toSet();
    case MemberRole.admin:
      return EmployeePermission.values
          .where((p) => !p.isOwnerOnly)
          .toSet();
    case MemberRole.user:
      return const {
        EmployeePermission.inventoryView,
        EmployeePermission.caisseAccess,
        EmployeePermission.caisseSell,
        EmployeePermission.crmView,
      };
  }
}

/// Presets de permissions pour faciliter la sélection dans le form.
class EmployeePermissionPresets {
  /// Toutes les permissions cochées (responsable total — y compris les
  /// permissions réservées owner). Réservé super-admin / debug.
  static Set<EmployeePermission> get full =>
      EmployeePermission.values.toSet();

  /// Admin : toutes les permissions sauf celles réservées au propriétaire
  /// (`shop.delete`, `admin.remove`). Aligné sur
  /// `defaultPermissionsForRole(MemberRole.admin)`.
  static Set<EmployeePermission> get admin => EmployeePermission.values
      .where((p) => !p.isOwnerOnly)
      .toSet();

  /// Personnel polyvalent : voir produits + encaisser + voir clients.
  /// Aligné sur `defaultPermissionsForRole(MemberRole.user)`.
  static Set<EmployeePermission> get employee => {
    EmployeePermission.inventoryView,
    EmployeePermission.caisseAccess,
    EmployeePermission.caisseSell,
    EmployeePermission.crmView,
  };

  /// Caissier standard : Personnel + édition de commandes et remises.
  static Set<EmployeePermission> get cashier => {
    ...employee,
    EmployeePermission.caisseEditOrders,
    EmployeePermission.salesDiscount,
    EmployeePermission.deliveryWhatsApp,
  };

  /// Gestionnaire de stock : tout l'inventaire + lecture caisse.
  static Set<EmployeePermission> get stockManager => {
    EmployeePermission.inventoryView,
    EmployeePermission.inventoryWrite,
    EmployeePermission.inventoryStock,
    EmployeePermission.caisseAccess,
    EmployeePermission.shopLocations,
  };

  // ── RESTAURATION ────────────────────────────────────────────────────────
  //
  // Trois préréglages taillés pour la salle, distincts de ceux du commerce :
  // un serveur n'est pas un « personnel polyvalent » (il ne doit pas voir le
  // carnet clients ni les commandes des autres), et un caissier de restaurant
  // remise une addition alors qu'il ne rembourse jamais une vente encaissée.
  //
  // Le fil conducteur : l'argent ne sort d'un restaurant sans qu'un plat sorte
  // que par deux portes — la remise et l'annulation d'une vente encaissée. La
  // première est accordée au caissier mais reste sous PIN gérant ; la seconde
  // n'est accordée à personne d'autre que la gérance.

  /// Serveur : prend les commandes, encaisse, et rien d'autre.
  ///
  /// Sans `caisseViewAllOrders` il ne voit QUE ses propres commandes (plus
  /// celles déjà finalisées) — il ne peut donc pas ouvrir ni modifier
  /// l'addition d'un collègue. Sans `inventoryWrite` il lit la carte sans
  /// pouvoir toucher à un prix. Pas de `crmView` : le carnet d'adresses de
  /// l'établissement n'a rien à faire entre ses mains.
  static Set<EmployeePermission> get waiter => {
    EmployeePermission.inventoryView,
    EmployeePermission.caisseAccess,
    EmployeePermission.caisseSell,
  };

  /// Caissier de restaurant : serveur + il encaisse pour toute la salle.
  ///
  /// `caisseViewAllOrders` parce qu'il encaisse les commandes des autres, et
  /// `salesDiscount` parce qu'un geste commercial fait partie du poste — mais
  /// la remise sur addition reste soumise au PIN gérant et journalisée.
  /// Volontairement SANS `salesCancel` : annuler une vente déjà encaissée est
  /// le geste qui permet d'empocher le comptant puis d'effacer la ligne.
  static Set<EmployeePermission> get restaurantCashier => {
    ...waiter,
    EmployeePermission.caisseEditOrders,
    EmployeePermission.caisseViewAllOrders,
    EmployeePermission.salesDiscount,
    EmployeePermission.crmView,
  };

  /// Cuisinier : voit tous les bons et fait avancer le service.
  ///
  /// La plupart des cuisiniers n'ont PAS besoin de compte — ils badgent avec
  /// leur code à 4 chiffres dans « Personnel ». Ce préréglage ne sert qu'à
  /// celui qui suit les commandes sur un écran. Ni vente, ni remise.
  static Set<EmployeePermission> get cook => {
    EmployeePermission.inventoryView,
    EmployeePermission.caisseAccess,
    EmployeePermission.caisseViewAllOrders,
  };

  /// Comptable : finances + rapports.
  static Set<EmployeePermission> get accountant => {
    EmployeePermission.inventoryView,
    EmployeePermission.crmView,
    EmployeePermission.financeView,
    EmployeePermission.financeExpenses,
    EmployeePermission.financeExport,
    EmployeePermission.shopActivity,
  };
}
