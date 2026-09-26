/// LE TICKET DE CAISSE DU RESTAURANT — ce qu'il dit, ligne par ligne.
///
/// Séparé du dessin (`core/services/resto_ticket_pdf.dart`) pour qu'on puisse
/// vérifier sans PDF la règle qui compte le plus : **une ligne dont la donnée
/// manque n'existe pas**. Elle ne s'imprime pas vide, et on n'invente rien
/// pour la remplir (26/09/2026).
///
/// Le ticket e-commerce ne passe PAS par ici : il garde sa mise en page
/// (`InvoiceService._buildTicketPage`). Le choix se fait sur le secteur de la
/// boutique.
library;

import '../../caisse/domain/entities/sale.dart';
import '../../caisse/domain/entities/sale_item.dart';
import '../../shop_selector/domain/entities/shop_summary.dart';
import 'entities/payment.dart';

/// Ce que le ticket lit HORS de la vente — plan de salle, membres,
/// règlements. Réuni par l'appelant (caches locaux), pour que ce fichier
/// reste pur.
class RestoTicketFacts {
  /// Nom de la table, tel que le plan de salle l'écrit. `null` hors salle.
  final String? tableName;

  /// Qui a pris la commande (`serverLabelFor`), jamais un identifiant.
  final String? serverName;

  /// Règlements de l'addition, du plus ancien au plus récent.
  final List<Payment> payments;

  /// Heure d'édition du ticket, pour le pied.
  final DateTime printedAt;

  const RestoTicketFacts({
    this.tableName,
    this.serverName,
    this.payments = const [],
    required this.printedAt,
  });
}

/// Une ligne à deux colonnes : [left] se replie si la place manque,
/// [right] garde sa largeur. L'une ou l'autre peut manquer, pas les deux.
class TicketPair {
  final String? left;
  final String? right;
  const TicketPair(this.left, this.right);
}

/// Libellé à gauche, montant à droite.
class TicketAmount {
  final String label;
  final String value;
  const TicketAmount(this.label, this.value);
}

/// Un article : nom et total sur la première ligne, « qté × prix » dessous.
class TicketItem {
  final String name;
  final String detail;
  final String total;
  const TicketItem(this.name, this.detail, this.total);
}

class RestoTicket {
  /// Nom de la boutique, en capitales.
  final String shopName;

  /// L'activité seule : la ville n'existe pas dans `shops`, et le pays n'en
  /// est pas une (décision du 26/09/2026 — mieux vaut moins que faux).
  final String activity;

  final String? phone;
  final List<TicketPair> ident;
  final List<TicketItem> items;

  /// Sous-total, remise, TVA, livraison, frais — tout ce qui précède le total.
  final List<TicketAmount> adjustments;
  final String total;

  /// Le bloc de règlement : chaque règlement, le rendu, le reste dû. Vide =
  /// pas de bloc.
  final List<TicketAmount> settlement;

  final String? note;

  /// Le pied, ligne par ligne. PAS de NIU : le champ n'existe pas encore
  /// (backlog, prioritaire). La ligne apparaîtra quand la donnée existera.
  final List<String> footer;

  const RestoTicket({
    required this.shopName,
    required this.activity,
    required this.phone,
    required this.ident,
    required this.items,
    required this.adjustments,
    required this.total,
    required this.settlement,
    required this.note,
    required this.footer,
  });

  /// [money] formate un montant — `CurrencyFormatter.format` en production.
  /// Injecté pour que ce fichier ne dépende d'aucune devise active.
  factory RestoTicket.from({
    required Sale sale,
    required ShopSummary shop,
    required RestoTicketFacts facts,
    required String Function(double) money,
  }) {
    String? clean(String? s) {
      final t = (s ?? '').trim();
      return t.isEmpty ? null : t;
    }

    final table = [clean(facts.tableName), clean(sale.tabLabel)]
        .whereType<String>()
        .join(' · ');
    final covers = sale.covers ?? 0;
    final server = clean(facts.serverName);
    final ref = shortRef(sale.id);
    final d = sale.createdAt.toLocal();

    final ident = <TicketPair>[
      TicketPair(ref == null ? null : 'Réf. $ref',
          table.isEmpty ? null : table),
      TicketPair('${_date(d)} · ${_time(d)}',
          covers > 0 ? '$covers couvert${covers > 1 ? 's' : ''}' : null),
      TicketPair(server == null ? null : 'Servi par $server',
          channelLabel(sale.orderType)),
    ].where((p) => p.left != null || p.right != null).toList();

    final discountReason = clean(sale.discountReason);
    final adjustments = <TicketAmount>[
      TicketAmount('Sous-total', money(sale.subtotal)),
      if (sale.discountAmount > 0)
        TicketAmount(
            discountReason == null ? 'Remise' : 'Remise · $discountReason',
            '− ${money(sale.discountAmount)}'),
      if (sale.taxRate > 0)
        TicketAmount('TVA (${sale.taxRate.toStringAsFixed(1)} %)',
            money(sale.taxAmount)),
      if (sale.deliveryFeeToFix)
        const TicketAmount('Livraison', 'À confirmer')
      else if ((sale.deliveryPrice ?? 0) > 0)
        TicketAmount('Livraison', money(sale.deliveryPrice!)),
      for (final f in sale.fees)
        if (((f['amount'] as num?)?.toDouble() ?? 0) > 0)
          TicketAmount(clean(f['label'] as String?) ?? 'Frais',
              money((f['amount'] as num).toDouble())),
    ];

    return RestoTicket(
      shopName: shop.name.trim().toUpperCase(),
      activity: 'Restaurant',
      phone: clean(shop.phone) == null ? null : 'Tél. ${shop.phone!.trim()}',
      ident: ident,
      items: [for (final i in sale.items) _item(i, money)],
      adjustments: adjustments,
      total: money(sale.total),
      settlement: _settlement(sale, facts.payments, money),
      note: clean(sale.notes),
      footer: [
        'Merci de votre visite',
        'Édité depuis Fortress POS · '
            '${_date(facts.printedAt.toLocal(), year: false)} '
            '${_time(facts.printedAt.toLocal())}',
      ],
    );
  }

  /// RÉFÉRENCE COURTE : les 6 derniers caractères de l'identifiant, en
  /// capitales — la même règle que la page de confirmation du catalogue
  /// (`ORD-XXXXXX`).
  ///
  /// « Réf. » et non « n° » : ce n'est PAS une séquence. L'ancien ticket
  /// imprimait les 8 PREMIERS caractères, soit « ORDER_17 » sur toutes les
  /// commandes du restaurant (`order_<millisecondes>` : « 17 » est le début
  /// de l'horodatage, commun à toutes). Un vrai numéro séquentiel est un lot
  /// de données à part.
  static String? shortRef(String? id) {
    final raw = (id ?? '').trim();
    if (raw.isEmpty) return null;
    final tail = raw.length > 6 ? raw.substring(raw.length - 6) : raw;
    return tail.toUpperCase();
  }

  /// Le canal, en mots de salle. Inconnu → pas de libellé.
  static String? channelLabel(String orderType) => switch (orderType) {
        'dine_in' => 'Sur place',
        'takeaway' => 'À emporter',
        'delivery' => 'Livraison',
        _ => null,
      };

  static TicketItem _item(SaleItem i, String Function(double) money) {
    final variant = (i.variantName ?? '').trim();
    return TicketItem(
      variant.isEmpty ? i.productName : '${i.productName} — $variant',
      '${i.quantity} × ${money(i.effectivePrice)}',
      money(i.subtotal),
    );
  }

  /// Le règlement : ce que le client vérifie en premier.
  ///
  /// Chaque règlement de l'addition, avec ce que le client a TENDU en
  /// espèces, puis le rendu sous lui. Sans règlement enregistré (commande
  /// antérieure au hotfix_145), le montant encaissé et le mode générique de
  /// la vente. Le reste dû ferme le bloc s'il y en a un.
  static List<TicketAmount> _settlement(
    Sale sale,
    List<Payment> payments,
    String Function(double) money,
  ) {
    final out = <TicketAmount>[];
    final real = payments.where((p) => !p.mode.isCredit && p.amount > 0);
    if (real.isNotEmpty) {
      for (final p in real) {
        final cash = p.mode.allowsChange;
        out.add(TicketAmount(
            p.mode.label, money((cash ? p.received : p.amount).toDouble())));
        if (cash && p.changeGiven > 0) {
          out.add(TicketAmount('Rendu', money(p.changeGiven.toDouble())));
        }
      }
    } else if (sale.amountPaid > 0) {
      final label = switch (sale.paymentMethod) {
        PaymentMethod.cash => 'Espèces',
        PaymentMethod.mobileMoney => 'Mobile Money',
        PaymentMethod.card => 'Carte',
        PaymentMethod.credit => 'Payé',
      };
      out.add(TicketAmount(label, money(sale.amountPaid)));
    }
    // LE RESTE DÛ LIT AUSSI LES RÈGLEMENTS. La vente à emporter imprime la
    // commande d'AVANT l'encaissement (`restaurant_checkout` : `settled =
    // order`) : son `amountPaid` vaut encore 0, et l'ancien ticket écrivait
    // « Reste dû » égal au total sur un ticket payé. Les règlements, eux,
    // sont enregistrés avant l'impression. Le plus grand des deux encaissés
    // fait foi ; sous 1, c'est l'arrondi d'un total non entier absorbé à
    // l'encaissement, pas une dette (le franc CFA n'a pas de centimes).
    final recorded = real.fold<int>(0, (s, p) => s + p.amount).toDouble();
    final paid = recorded > sale.amountPaid ? recorded : sale.amountPaid;
    final due = sale.isFullyPaid ? 0.0 : sale.total - paid;
    if (due >= 1) {
      out.add(TicketAmount('Reste dû', money(due)));
    }
    return out;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _date(DateTime d, {bool year = true}) =>
      '${_two(d.day)}/${_two(d.month)}${year ? '/${d.year}' : ''}';
  static String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
}
