import '../../../parametres/domain/entities/delivery_template.dart';
import '../entities/sale.dart';
import '../entities/sale_item.dart';

/// Rend un template `{{variable}}` en message texte WhatsApp final, à partir
/// d'une [Sale] (commande) et du nom de la boutique.
///
/// VARIABLES SUPPORTÉES (cf. spec) :
///   {{caisse}} {{client_name}} {{client_phone}} {{lieu_livraison}}
///   {{produits}} {{date}} {{heure}} {{prix_produit}}
///   {{frais_livraison}} {{total}} {{notes}}
///   {{ville_expedition}} (cf. hotfix_049 — ville du destinataire,
///                         partenaire ou employé)
///
/// RÈGLES DE FORMATAGE PRIX (auto, pas user-configurable) :
///   • 1 produit qty=1  → "5 000 XAF (qté 1)"
///   • 1 produit qty>1  → "5 000 × 3 = 15 000 XAF"
///   • N produits       → multi-ligne, chaque ligne `• Nom — calcul`
///   • frais=0          → "inclus dans le prix"
///   • acompte présent  → "X XAF (acompte Y XAF déjà reçu, reste Z XAF)"
///
/// RÈGLE DROP-LIGNE (heuristique) :
///   Si après remplacement une ligne match `^[^{}]*\{\{var\}\}\s*$` ET que
///   `var` est vide, la ligne entière est supprimée du rendu final. Évite
///   d'envoyer "Notes : " quand il n'y a pas de notes.
///   Implémenté via regex sur le template AVANT remplacement : on identifie
///   les lignes "label + {{var}}" et on les retire si la variable résolue
///   est vide.
class DeliveryMessageBuilder {
  /// Construit le message à envoyer depuis [template] et [sale].
  ///
  /// [shopName]      : nom de la boutique (variable {{caisse}}).
  /// [paidAmount]    : si non null et > 0, mention "(acompte X reçu)" dans
  ///                   {{total}} avec calcul du reste.
  /// [senderCity]    : ville d'expédition (du partenaire ou de l'employé
  ///                   à qui on transfère la commande). Résout
  ///                   {{ville_expedition}}.
  /// [clientDistrict]: quartier du client résolu (typiquement
  ///                   `Client.district` via `sale.clientId`). Utilisé
  ///                   en priorité pour `{{lieu_livraison}}`. Fallback
  ///                   sur `sale.deliveryAddress` si null/vide.
  /// [resolveProductName] : callback qui retourne le nom du produit
  ///                   (Product.name défini lors de l'enregistrement)
  ///                   pour un SaleItem donné. Si null/vide, fallback
  ///                   sur le `productName` stocké dans SaleItem.
  static String build({
    required DeliveryTemplate template,
    required Sale             sale,
    required String           shopName,
    double?                   paidAmount,
    String?                   senderCity,
    String?                   clientDistrict,
    String? Function(SaleItem item)? resolveProductName,
  }) {
    final values = _resolveVariables(
        sale, shopName, paidAmount, senderCity,
        clientDistrict, resolveProductName);
    return _renderWithDropEmpty(template.body, values);
  }

  // ── Résolution variables ───────────────────────────────────────────────

  static Map<String, String> _resolveVariables(
      Sale sale, String shopName, double? paidAmount, String? senderCity,
      String? clientDistrict,
      String? Function(SaleItem)? resolveProductName) {
    final lieu = _formatLieuLivraison(sale, clientDistrict);
    final productsBlock = _formatProducts(sale.items, resolveProductName);
    final feesAmount    = _deliveryFeeAmount(sale.fees);
    final feesText      = feesAmount <= 0
        ? 'inclus dans le prix'
        : _formatAmount(feesAmount);
    final productsTotal = sale.items.fold<double>(
        0, (s, i) => s + (i.unitPrice * i.quantity));
    final grandTotal    = productsTotal + feesAmount;
    final totalText     = _formatTotalWithAcompte(grandTotal, paidAmount);

    final scheduled = sale.scheduledAt;
    return {
      'caisse'         : shopName,
      'client_name'    : (sale.clientName  ?? '').trim(),
      'client_phone'   : (sale.clientPhone ?? '').trim(),
      'lieu_livraison' : lieu,
      'produits'       : productsBlock,
      'date'           : scheduled != null ? _formatDate(scheduled) : '',
      'heure'          : scheduled != null ? _formatTime(scheduled) : '',
      'prix_produit'   : _formatAmount(productsTotal),
      'frais_livraison': feesText,
      'total'          : totalText,
      'notes'          : (sale.notes ?? '').trim(),
      'ville_expedition': (senderCity ?? '').trim(),
    };
  }

  // ── Lieu de livraison : QUARTIER du client (cf. spec). ──
  // Ordre de résolution :
  //   1. clientDistrict (typique pour les commandes web — depuis
  //      Client.district, hotfix_047)
  //   2. sale.deliveryAddress (typique pour les commandes en boutique)
  //   3. sale.deliveryCity (fallback si district vide)
  //   4. "—"
  static String _formatLieuLivraison(Sale sale, String? clientDistrict) {
    final fromClient = (clientDistrict ?? '').trim();
    if (fromClient.isNotEmpty) return fromClient;
    final district = (sale.deliveryAddress ?? '').trim();
    if (district.isNotEmpty) return district;
    final city = (sale.deliveryCity ?? '').trim();
    if (city.isNotEmpty) return city;
    return '—';
  }

  // ── Frais de livraison : somme des fees dont le label contient "livraison"
  // (insensible à la casse). Si aucun match → 0. Permet aux frais nommés
  // différemment (ex: "Transport") de ne PAS être comptés comme livraison.
  static double _deliveryFeeAmount(List<Map<String, dynamic>> fees) {
    double sum = 0;
    for (final f in fees) {
      final label = (f['label'] ?? '').toString().toLowerCase();
      if (label.contains('livraison') || label.contains('delivery')) {
        sum += (f['amount'] as num?)?.toDouble() ?? 0;
      }
    }
    return sum;
  }

  // ── Formatage produits ─────────────────────────────────────────────────
  static String _formatProducts(
      List<SaleItem> items, String? Function(SaleItem)? resolveName) {
    if (items.isEmpty) return '—';
    if (items.length == 1) {
      final i = items.first;
      return '• ${_itemLabel(i, resolveName)} — ${_formatItemLine(i)}';
    }
    // Multi-ligne, chaque ligne `• Nom — calcul`.
    return items.map((i) =>
        '• ${_itemLabel(i, resolveName)} — ${_formatItemLine(i)}').join('\n');
  }

  /// Nom du produit affiché : `Product.name` (champ principal défini lors
  /// de l'enregistrement) résolu via `resolveName`. Si null/vide, fallback
  /// sur le `productName` stocké dans le SaleItem (le nom au moment de
  /// la vente, peut différer si le produit a été renommé depuis).
  static String _itemLabel(
      SaleItem i, String? Function(SaleItem)? resolveName) {
    if (resolveName != null) {
      final name = resolveName(i)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return i.productName;
  }

  /// Calcul d'une ligne :
  ///   • qty=1 → "5 000 XAF (qté 1)"
  ///   • qty>1 → "5 000 × 3 = 15 000 XAF"
  static String _formatItemLine(SaleItem i) {
    final unit  = i.customPrice ?? i.unitPrice;
    final qty   = i.quantity;
    final total = unit * qty;
    if (qty <= 1) {
      return '${_formatAmount(unit)} (qté 1)';
    }
    return '${_formatAmount(unit)} × $qty = ${_formatAmount(total)}';
  }

  // ── Total avec mention acompte si applicable ──────────────────────────
  static String _formatTotalWithAcompte(double total, double? paid) {
    if (paid == null || paid <= 0) return _formatAmount(total);
    final rest = total - paid;
    return '${_formatAmount(total)} '
        '(acompte ${_formatAmount(paid)} déjà reçu, '
        'reste ${_formatAmount(rest)})';
  }

  // ── Format montant : "1 234 567 XAF" (espace fine, pas de décimales) ─
  static String _formatAmount(double amount) {
    final i = amount.round();
    final s = i.toString();
    final buf = StringBuffer();
    for (var k = 0; k < s.length; k++) {
      if (k > 0 && (s.length - k) % 3 == 0) buf.write(' ');
      buf.write(s[k]);
    }
    return '${buf.toString()} XAF';
  }

  // ── Format date : "lun 4 mai" ─────────────────────────────────────────
  static String _formatDate(DateTime d) {
    const days   = ['lun', 'mar', 'mer', 'jeu', 'ven', 'sam', 'dim'];
    const months = ['jan', 'fév', 'mar', 'avr', 'mai', 'juin',
                    'juil', 'août', 'sep', 'oct', 'nov', 'déc'];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }

  // ── Format heure : "14:00" ────────────────────────────────────────────
  static String _formatTime(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  // ── Rendu avec drop-ligne pour variables vides ────────────────────────
  static String _renderWithDropEmpty(
      String template, Map<String, String> values) {
    // Étape 1 : pour chaque ligne, si elle ne contient QU'un seul placeholder
    // optionnel `{{var}}` (avec éventuellement un label/préfixe avant) ET
    // que la variable est vide, on supprime la ligne entière.
    final lines = template.split('\n');
    final kept  = <String>[];
    // Regex : capture une ligne qui contient exactement un placeholder
    // (toléré : texte avant + espaces). Si la valeur résolue est vide, drop.
    final singleVarLine = RegExp(r'^[^{}]*\{\{(\w+)\}\}\s*$');
    for (final line in lines) {
      final m = singleVarLine.firstMatch(line);
      if (m != null) {
        final key = m.group(1)!;
        final val = values[key] ?? '';
        if (val.trim().isEmpty) continue; // drop cette ligne
      }
      kept.add(line);
    }
    var rendered = kept.join('\n');
    // Étape 2 : remplacement global des placeholders restants.
    values.forEach((k, v) {
      rendered = rendered.replaceAll('{{$k}}', v);
    });
    // Étape 3 : nettoyage — collapse 3+ retours à la ligne consécutifs en 2.
    rendered = rendered.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return rendered;
  }
}
