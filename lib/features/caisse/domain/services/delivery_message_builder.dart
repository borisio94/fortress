import '../../../inventaire/domain/entities/product.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../../parametres/domain/entities/delivery_template.dart';
import '../entities/sale.dart';
import '../entities/sale_item.dart';

/// Rend un template `{{variable}}` en message texte WhatsApp final, à partir
/// d'une [Sale] (commande) et du nom de la boutique.
///
/// VARIABLES SUPPORTÉES (cf. spec) :
///   {{caisse}} {{client_name}} {{client_phone}} {{lieu_livraison}}
///   {{titre_livraison}} (« NOUVELLE LIVRAISON » ou « LIVRAISON RELANCÉE »
///                        selon que la commande a été reprogrammée)
///   {{reference}} (référence courte de la commande, 6 derniers car. UUID)
///   {{date}} {{heure}} {{prix_produit}}
///   {{frais_livraison}} {{total}} {{notes}}
///   {{ville_expedition}} (cf. hotfix_049 — ville du destinataire,
///                         partenaire ou employé)
///   {{partner_name}} {{partner_phone}} {{partner_city}} {{partner_notes}}
///   (cf. hotfix_093 — résolus depuis la StockLocation cible quand le
///    transfert vise un partenaire ; sinon chaînes vides → la ligne
///    correspondante est éliminée par la règle drop-ligne).
///
/// VARIABLES « PRODUITS » :
///   {{produits}}      → lien court vers la mini-vitrine produits de la
///                       commande (images + quantités) quand on est en
///                       contexte d'envoi (le caller passe `productsLink`).
///                       Sans contexte (copier depuis la page Modèles),
///                       retombe sur la liste texte multi-ligne.
///   {{produits_link}} → identique à {{produits}} en contexte envoi.
///                       Reste vide hors-contexte (et la ligne
///                       correspondante est dropée par la règle drop-ligne).
///   {{produits_text}} → toujours la liste texte multi-ligne
///                       (« • Nom — calcul ») pour les utilisateurs qui
///                       veulent l'ancien format quel que soit le contexte.
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
    /// Partenaire destinataire — résout les variables `{{partner_*}}`.
    /// Null pour un employé ou un numéro libre : ces variables seront
    /// vides et leurs lignes filtrées par la règle drop-ligne.
    StockLocation?            partner,
    /// URL (idéalement courte, cf. ShortLinkService) vers la mini-vitrine
    /// produits de la commande. Si fournie, `{{produits}}` et
    /// `{{produits_link}}` s'y résolvent. Si null, `{{produits}}` retombe
    /// sur la liste texte (cas du copier-coller depuis la page Modèles
    /// où aucun order context n'est dispo).
    String?                   productsLink,
    String? Function(SaleItem item)? resolveProductName,
    /// Résout le SKU du produit/variante d'un SaleItem. Si fourni et non
    /// vide, le SKU est affiché À LA PLACE du nom dans la liste texte
    /// (`produits_text` / `produits` en mode texte) — identifiant précis
    /// pour le livreur. Fallback sur le nom si le SKU est absent.
    String? Function(SaleItem item)? resolveProductSku,
  }) {
    final values = _resolveVariables(
        sale, shopName, paidAmount, senderCity,
        clientDistrict, partner, productsLink, resolveProductName,
        resolveProductSku);
    return _renderWithDropEmpty(template.body, values);
  }

  /// Construit l'URL longue vers la mini-vitrine catalogue d'une commande,
  /// prête à être passée à `ShortLinkService.createShortLink` puis utilisée
  /// comme `productsLink` dans [build]. Format :
  ///   `<base>/catalogue/<shopId>?ids=<id1,id2>&stock=<id1:qty,id2|var:qty>
  ///    &loc=<deliveryLocationId>`
  /// `base` est l'URL canonique de l'app (web), passée par le caller —
  /// permet de tester en local sans hardcoder le domaine prod. Path
  /// routing (sans `#`) depuis main.usePathUrlStrategy — les in-app
  /// browsers WhatsApp préservent ainsi les query params lors d'une 302.
  ///
  /// [products] : catalogue local complet du shop (depuis Hive). Sert à
  /// résoudre les `SaleItem.productId` qui sont en réalité des IDs de
  /// VARIANTE (format `var_…`) vers leur produit parent. Le catalogue
  /// page expose les variantes en cards séparées sous le produit parent ;
  /// donc on passe le PARENT dans `ids=` et on encode la variante dans
  /// `stock=` au format `parentId|variantId:qty` (déjà supporté côté
  /// page, cf. app_router catalogue route). Si [products] est null ou
  /// vide, fallback sur l'ancien comportement (productId tel quel) pour
  /// rester rétro-compatible.
  static String buildCatalogueLongUrl({
    required String        webBase,
    required String        shopId,
    required Sale          sale,
    List<Product>?         products,
  }) {
    // Index pour résolution rapide : productId → product et variantId → parent.
    final byProductId = <String, Product>{};
    final variantToParent = <String, String>{}; // variantId → parent.id
    if (products != null) {
      for (final p in products) {
        final pid = p.id;
        if (pid != null && pid.isNotEmpty) byProductId[pid] = p;
        for (final v in p.variants) {
          final vid = v.id;
          if (vid != null && vid.isNotEmpty && pid != null) {
            variantToParent[vid] = pid;
          }
        }
      }
    }

    // Résolution de chaque SaleItem.productId :
    //   - id matche un produit → c'est un productId, on garde
    //   - id matche un variantId connu → on remplace par parentId,
    //     et on note la variante pour le stock
    //   - sinon (vieux records, products non chargés…) → on garde tel quel
    //
    // Format clé snapshot pour les variantes : `parentId|<idx>` où idx =
    // position dans `realVariants` (variantes filtrées avec name non vide).
    // Aligné avec `_buildStockSnapshot` (inventaire) ET `catalogue_page._load`
    // pour que :
    //   1. le snapshot de stock soit correctement matché côté catalogue,
    //   2. la CataloguePage puisse filtrer les variantes affichées (n'expose
    //      QUE les variantes commandées, pas toutes les variantes du parent
    //      — sinon le client voit 4 variantes alors qu'il n'a commandé qu'une
    //      seule couleur, cf. bug rapporté 2026-05-28).
    final parentIds = <String>{};
    final stockTokens = <String>[];
    for (final it in sale.items) {
      final raw = it.productId;
      if (raw.isEmpty) continue;
      String parentId;
      String? variantToken; // idx dans realVariants OU variantId (fallback)
      if (byProductId.containsKey(raw)) {
        parentId = raw;
      } else if (variantToParent.containsKey(raw)) {
        parentId = variantToParent[raw]!;
        final parent = byProductId[parentId];
        if (parent != null) {
          final realVariants =
              parent.variants.where((v) => v.name.trim().isNotEmpty).toList();
          final idx = realVariants.indexWhere((v) => v.id == raw);
          variantToken = idx >= 0 ? '$idx' : raw; // fallback : variantId brut
        } else {
          variantToken = raw;
        }
      } else {
        // Fallback rétro-compat — on passe tel quel.
        parentId = raw;
      }
      parentIds.add(parentId);
      // Format catalogue : `productId|<idx>:qty` pour une variante,
      // `productId:qty` sinon. Voir app_router catalogue route.
      final key =
          variantToken == null ? parentId : '$parentId|$variantToken';
      stockTokens.add('$key:${it.quantity}');
    }

    final qp = <String>[];
    if (parentIds.isNotEmpty) qp.add('ids=${parentIds.join(",")}');
    if (stockTokens.isNotEmpty) qp.add('stock=${stockTokens.join(",")}');
    final loc = (sale.deliveryLocationId ?? '').trim();
    if (loc.isNotEmpty) qp.add('loc=$loc');
    // Mode delivery : la CataloguePage simplifie l'affichage (uniquement
    // image + quantité à livrer ; pas de nom/prix/stock/commande). Le
    // livreur n'a besoin que d'une fiche visuelle pour reconnaître les
    // produits à livrer.
    qp.add('mode=delivery');
    final base = '$webBase/catalogue/$shopId';
    return '$base?${qp.join("&")}';
  }

  // ── Résolution variables ───────────────────────────────────────────────

  static Map<String, String> _resolveVariables(
      Sale sale, String shopName, double? paidAmount, String? senderCity,
      String? clientDistrict, StockLocation? partner,
      String? productsLink,
      String? Function(SaleItem)? resolveProductName,
      [String? Function(SaleItem)? resolveProductSku]) {
    final lieu = _formatLieuLivraison(sale, clientDistrict);
    final productsText =
        _formatProducts(sale.items, resolveProductName, resolveProductSku);
    // {{produits}} : lien si fourni, sinon texte (compat copier-coller).
    final produitsValue = (productsLink != null && productsLink.isNotEmpty)
        ? productsLink
        : productsText;
    final feesAmount    = _deliveryFeeAmount(sale.fees);
    // Frais de livraison affichés = prix du quartier (`deliveryPrice`, PR-2/3)
    // + éventuels frais legacy étiquetés « livraison ». « à confirmer » pour
    // une commande web dont le quartier n'est pas répertorié (deliveryPrice
    // null). Le TOTAL ci-dessous n'est PAS double-compté : `sale.total` inclut
    // déjà `deliveryPrice`, on n'ajoute donc que `feesAmount` (legacy).
    final deliveryTotal = (sale.deliveryPrice ?? 0) + feesAmount;
    final feesText      = sale.deliveryFeeToFix
        ? 'à confirmer'
        : (deliveryTotal <= 0
            ? 'inclus dans le prix'
            : _formatAmount(deliveryTotal));
    // {{prix_produit}} et {{total}} doivent EXACTEMENT matcher la facture
    // (cf. ticket 2026-05-28). On utilise donc `sale.subtotal` et
    // `sale.total` qui prennent en compte :
    //   • `customPrice` saisi par le marchand (prix modifié pour la vente)
    //   • `discount` par ligne
    //   • `discountAmount` global
    //   • `taxAmount`
    // Avant fix : `sum(i.unitPrice * i.quantity)` ignorait customPrice et
    // discount → le message livreur affichait le prix CATALOGUE alors que
    // la facture affichait le prix négocié. Discrepancy ≠ 0.
    //
    // `sale.total` inclut DÉSORMAIS toutes les dépenses (livraison
    // [deliveryPrice] + autres frais [totalFees]) qui s'ajoutent au prix de
    // vente. On NE rajoute donc plus `feesAmount` (sinon double comptage des
    // frais de livraison saisis en `fees`). `{{total}}` = ce que le livreur
    // encaisse au total.
    final productsTotal = sale.subtotal;
    final grandTotal    = sale.total;
    final totalText     = _formatTotalWithAcompte(grandTotal, paidAmount);

    // Ville du partenaire : combine district + city si les deux sont
    // présents, sinon prend ce qui est dispo. Sert de fallback explicite
    // à ville_expedition quand le user ne saisit rien.
    String partnerCity() {
      if (partner == null) return '';
      final d = (partner.district ?? '').trim();
      final c = (partner.city     ?? '').trim();
      if (d.isNotEmpty && c.isNotEmpty) return '$d, $c';
      if (d.isNotEmpty) return d;
      if (c.isNotEmpty) return c;
      return (partner.address ?? '').trim();
    }

    final scheduled = sale.scheduledAt;
    return {
      'caisse'         : shopName,
      // Titre dynamique selon le statut de la livraison : « LIVRAISON
      // RELANCÉE » si la commande a été reprogrammée (rescheduleReason
      // non vide sert de marqueur, cf. Sale.rescheduleReason), sinon
      // « NOUVELLE LIVRAISON ».
      'titre_livraison': (sale.rescheduleReason ?? '').trim().isNotEmpty
          ? 'LIVRAISON RELANCÉE'
          : 'NOUVELLE LIVRAISON',
      // Référence courte et lisible de la commande (alignée sur le reçu).
      'reference'      : _formatReference(sale),
      'client_name'    : (sale.clientName  ?? '').trim(),
      'client_phone'   : (sale.clientPhone ?? '').trim(),
      'lieu_livraison' : lieu,
      'produits'       : produitsValue,
      'produits_link'  : productsLink ?? '',
      'produits_text'  : productsText,
      'date'           : scheduled != null ? _formatDate(scheduled) : '',
      'heure'          : scheduled != null ? _formatTime(scheduled) : '',
      'prix_produit'   : _formatAmount(productsTotal),
      'frais_livraison': feesText,
      'total'          : totalText,
      'notes'          : (sale.notes ?? '').trim(),
      'ville_expedition': (senderCity ?? '').trim(),
      // ── Variables partenaire (hotfix_093) — vides si pas de partenaire.
      'partner_name'   : partner?.name.trim() ?? '',
      'partner_phone'  : (partner?.phone ?? '').trim(),
      'partner_city'   : partnerCity(),
      'partner_notes'  : (partner?.notes ?? '').trim(),
    };
  }

  // ── Référence courte d'une commande pour le message livreur. ──
  // Aligné avec le reçu (`OrderReceiptUseCase`) : 6 derniers caractères de
  // l'UUID en majuscules. Fallback sur un hash de la date de création pour
  // les ventes locales pas encore persistées (id null).
  static String _formatReference(Sale sale) {
    final id = (sale.id ?? '').trim();
    if (id.length >= 6) return id.substring(id.length - 6).toUpperCase();
    if (id.isNotEmpty) return id.toUpperCase();
    return sale.createdAt.millisecondsSinceEpoch
        .toRadixString(16)
        .toUpperCase();
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
      List<SaleItem> items, String? Function(SaleItem)? resolveName,
      [String? Function(SaleItem)? resolveSku]) {
    if (items.isEmpty) return '—';
    if (items.length == 1) {
      final i = items.first;
      return '• ${_itemLabel(i, resolveName, resolveSku)} — ${_formatItemLine(i)}';
    }
    // Multi-ligne, chaque ligne `• Label — calcul`.
    return items.map((i) =>
        '• ${_itemLabel(i, resolveName, resolveSku)} — ${_formatItemLine(i)}')
        .join('\n');
  }

  /// Libellé du produit affiché. Priorité : SKU (identifiant précis pour le
  /// livreur, via `resolveSku`), sinon `Product.name` (via `resolveName`),
  /// sinon le `productName` figé dans le SaleItem.
  static String _itemLabel(
      SaleItem i, String? Function(SaleItem)? resolveName,
      [String? Function(SaleItem)? resolveSku]) {
    if (resolveSku != null) {
      final sku = resolveSku(i)?.trim();
      if (sku != null && sku.isNotEmpty) return sku;
    }
    if (resolveName != null) {
      final name = resolveName(i)?.trim();
      if (name != null && name.isNotEmpty) return name;
    }
    return i.productName;
  }

  /// Calcul d'une ligne :
  ///   • qty=1 → "5 000 XAF (qté 1)"
  ///   • qty>1 → "5 000 × 3 = 15 000 XAF"
  ///
  /// Le prix unitaire affiché = `i.effectivePrice` (customPrice si défini,
  /// sinon unitPrice) — aligné avec la facture. Le total ligne =
  /// `i.subtotal` qui inclut aussi le discount par ligne s'il y en a un.
  /// Sans ce dernier alignement, le marchand qui applique un rabais
  /// pourrait voir une ligne « 5 000 × 3 = 15 000 » dans le message
  /// livreur alors que la facture montre 14 250 (5% de remise).
  static String _formatItemLine(SaleItem i) {
    final unit  = i.effectivePrice;
    final qty   = i.quantity;
    final total = i.subtotal;
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
