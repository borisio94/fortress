import 'package:equatable/equatable.dart';
import '../../../../core/storage/schema_migrator.dart';

/// Niveau hiérarchique courant d'un ticket. Détermine qui le voit en
/// priorité dans son inbox.
enum TicketLevel { admin, owner, superAdmin }

extension TicketLevelX on TicketLevel {
  String get key => switch (this) {
        TicketLevel.admin       => 'admin',
        TicketLevel.owner       => 'owner',
        TicketLevel.superAdmin  => 'super_admin',
      };

  String get labelFr => switch (this) {
        TicketLevel.admin       => 'En attente admin',
        TicketLevel.owner       => 'En attente propriétaire',
        TicketLevel.superAdmin  => 'En attente support',
      };

  static TicketLevel fromKey(String? k) => switch (k) {
        'owner'        => TicketLevel.owner,
        'super_admin'  => TicketLevel.superAdmin,
        _              => TicketLevel.admin,
      };
}

/// Statut métier du ticket.
enum TicketStatus { open, resolved, closed }

extension TicketStatusX on TicketStatus {
  String get key => switch (this) {
        TicketStatus.open      => 'open',
        TicketStatus.resolved  => 'resolved',
        TicketStatus.closed    => 'closed',
      };

  String get labelFr => switch (this) {
        TicketStatus.open      => 'Ouvert',
        TicketStatus.resolved  => 'Résolu',
        TicketStatus.closed    => 'Clôturé',
      };

  static TicketStatus fromKey(String? k) => switch (k) {
        'resolved'  => TicketStatus.resolved,
        'closed'    => TicketStatus.closed,
        _           => TicketStatus.open,
      };
}

/// Priorité informative.
enum TicketPriority { low, normal, high }

extension TicketPriorityX on TicketPriority {
  String get key => switch (this) {
        TicketPriority.low     => 'low',
        TicketPriority.normal  => 'normal',
        TicketPriority.high    => 'high',
      };

  String get labelFr => switch (this) {
        TicketPriority.low     => 'Basse',
        TicketPriority.normal  => 'Normale',
        TicketPriority.high    => 'Haute',
      };

  static TicketPriority fromKey(String? k) => switch (k) {
        'low'   => TicketPriority.low,
        'high'  => TicketPriority.high,
        _       => TicketPriority.normal,
      };
}

/// Catégorie informative pour faciliter le tri (stock, caisse, RH, autre).
/// Pas de contrainte SQL — l'app peut faire évoluer la liste.
class TicketCategory {
  static const stock   = 'stock';
  static const caisse  = 'caisse';
  static const rh      = 'rh';
  static const autre   = 'autre';

  static String labelFr(String? key) => switch (key) {
        'stock'   => 'Stock',
        'caisse'  => 'Caisse',
        'rh'      => 'RH',
        'autre'   => 'Autre',
        _         => 'Autre',
      };

  static const values = [stock, caisse, rh, autre];
}

class ShopTicket extends Equatable {
  final String         id;
  final String         shopId;
  final String         openedBy;
  final TicketLevel    currentLevel;
  final String?        category;
  final String         subject;
  final TicketStatus   status;
  final TicketPriority priority;
  final DateTime       createdAt;
  final DateTime       updatedAt;
  final DateTime?      resolvedAt;

  const ShopTicket({
    required this.id,
    required this.shopId,
    required this.openedBy,
    required this.currentLevel,
    this.category,
    required this.subject,
    this.status     = TicketStatus.open,
    this.priority   = TicketPriority.normal,
    required this.createdAt,
    required this.updatedAt,
    this.resolvedAt,
  });

  ShopTicket copyWith({
    TicketLevel?   currentLevel,
    String?        category,
    String?        subject,
    TicketStatus?  status,
    TicketPriority? priority,
    DateTime?      updatedAt,
    DateTime?      resolvedAt,
    bool clearResolvedAt = false,
  }) => ShopTicket(
        id:           id,
        shopId:       shopId,
        openedBy:     openedBy,
        currentLevel: currentLevel ?? this.currentLevel,
        category:     category ?? this.category,
        subject:      subject ?? this.subject,
        status:       status ?? this.status,
        priority:     priority ?? this.priority,
        createdAt:    createdAt,
        updatedAt:    updatedAt ?? this.updatedAt,
        resolvedAt:   clearResolvedAt ? null : (resolvedAt ?? this.resolvedAt),
      );

  // Schema versioning — cf. lib/core/storage/schema_migrator.dart.
  static const int currentSchemaVersion = 1;
  static final SchemaMigrator _migrator = SchemaMigrator(
    currentVersion: currentSchemaVersion, steps: const {});

  Map<String, dynamic> toMap() => {
        'schema_version': currentSchemaVersion,
        'id':            id,
        'shop_id':       shopId,
        'opened_by':     openedBy,
        'current_level': currentLevel.key,
        'category':      category,
        'subject':       subject,
        'status':        status.key,
        'priority':      priority.key,
        'created_at':    createdAt.toIso8601String(),
        'updated_at':    updatedAt.toIso8601String(),
        'resolved_at':   resolvedAt?.toIso8601String(),
      };

  factory ShopTicket.fromMap(Map<String, dynamic> rawM) {
    final m = _migrator.migrate(rawM);
    return ShopTicket(
        id:           m['id'] as String,
        shopId:       m['shop_id'] as String,
        openedBy:     m['opened_by'] as String,
        currentLevel: TicketLevelX.fromKey(m['current_level'] as String?),
        category:     m['category'] as String?,
        subject:      (m['subject'] as String?) ?? '',
        status:       TicketStatusX.fromKey(m['status'] as String?),
        priority:     TicketPriorityX.fromKey(m['priority'] as String?),
        createdAt:    DateTime.tryParse(m['created_at']?.toString() ?? '')
                       ?? DateTime.now(),
        updatedAt:    DateTime.tryParse(m['updated_at']?.toString() ?? '')
                       ?? DateTime.now(),
        resolvedAt:   m['resolved_at'] != null
                        ? DateTime.tryParse(m['resolved_at'].toString())
                        : null,
      );
  }

  @override
  List<Object?> get props => [id, shopId, openedBy, currentLevel,
      category, subject, status, priority, createdAt, updatedAt, resolvedAt];
}

class ShopTicketMessage extends Equatable {
  final String   id;
  final String   ticketId;
  final String   authorId;
  final String   body;
  final DateTime createdAt;

  const ShopTicketMessage({
    required this.id,
    required this.ticketId,
    required this.authorId,
    required this.body,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id':         id,
        'ticket_id':  ticketId,
        'author_id':  authorId,
        'body':       body,
        'created_at': createdAt.toIso8601String(),
      };

  factory ShopTicketMessage.fromMap(Map<String, dynamic> m) =>
      ShopTicketMessage(
        id:        m['id'] as String,
        ticketId:  m['ticket_id'] as String,
        authorId:  m['author_id'] as String,
        body:      (m['body'] as String?) ?? '',
        createdAt: DateTime.tryParse(m['created_at']?.toString() ?? '')
                    ?? DateTime.now(),
      );

  @override
  List<Object?> get props => [id, ticketId, authorId, body, createdAt];
}
