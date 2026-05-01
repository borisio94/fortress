/// Rôle canonique d'un membre dans une boutique.
///
/// Source de vérité côté Dart pour `shop_memberships.role`. Aligné sur la
/// CHECK constraint SQL `role IN ('owner','admin','user')` (cf.
/// hotfix_024_roles_permissions.sql).
///
/// **Hiérarchie** :
///   - `owner` : propriétaire de la boutique. Peut tout. Un seul par
///     boutique (= `shops.owner_id`).
///   - `admin` : co-administrateur désigné. Peut presque tout, sauf
///     supprimer la boutique et retirer un admin (réservé au owner).
///     Max 2 par boutique (3 admins au total avec le owner).
///   - `user`  : employé courant. Permissions explicites uniquement
///     (rien par défaut).
enum MemberRole { owner, admin, user }

extension MemberRoleX on MemberRole {
  /// Clé persistée dans `shop_memberships.role` et utilisée dans les RPCs.
  String get key => name; // 'owner' | 'admin' | 'user'

  /// Libellé FR pour l'UI. Centralisé ici pour cohérence.
  String get labelFr => switch (this) {
        MemberRole.owner => 'Propriétaire',
        MemberRole.admin => 'Administrateur',
        MemberRole.user  => 'Employé',
      };

  /// Indique si ce rôle peut gérer (créer/modifier/supprimer) un autre
  /// membre du rôle [target]. Implémente la hiérarchie :
  ///   - owner peut gérer admin et user
  ///   - admin peut gérer user uniquement
  ///   - user ne peut gérer personne
  bool canManage(MemberRole target) => switch (this) {
        MemberRole.owner => target != MemberRole.owner,
        MemberRole.admin => target == MemberRole.user,
        MemberRole.user  => false,
      };

  /// Parse depuis la valeur brute lue en DB. Tolère les casts text/null.
  static MemberRole fromString(String? s) => switch (s?.toLowerCase()) {
        'owner' => MemberRole.owner,
        'admin' => MemberRole.admin,
        _       => MemberRole.user,
      };
}
