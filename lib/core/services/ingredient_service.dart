import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/daily_expense.dart';
import '../../features/restaurant/domain/entities/ingredient.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'daily_expense_service.dart';

/// Service Hive-first du catalogue d'ingrédients (module finances — PR-A).
///
/// Même triptyque que [MenuModifierService] : écriture Hive immédiate → push
/// Supabase en arrière-plan (`bgUpsert`) → notification des listeners. Ids
/// générés côté client (`ig_` + microsecondes) → utilisable hors ligne.
class IngredientService {
  IngredientService._();

  static Box<Map> _raw() => HiveBoxes.ingredientsBox;

  static String _id() => 'ig_${DateTime.now().microsecondsSinceEpoch}';

  /// Tous les ingrédients de la boutique, triés par nom.
  static List<Ingredient> forShop(String shopId) {
    try {
      final list = <Ingredient>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(Ingredient.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return list;
    } catch (e) {
      debugPrint('[Ingredient] forShop err: $e');
      return [];
    }
  }

  static Ingredient? byId(String shopId, String id) {
    try {
      final raw = _raw().get(id);
      if (raw == null) return null;
      final ing = Ingredient.fromMap(Map<String, dynamic>.from(raw));
      return ing.shopId == shopId ? ing : null;
    } catch (_) {
      return null;
    }
  }

  /// Crée un ingrédient et le retourne (pour l'attacher aussitôt à une
  /// recette). `type` par défaut 'specialized' ; il bascule en 'shared'
  /// automatiquement dès qu'un même ingrédient est lié à ≥ 2 plats
  /// (maintenu par `RecipeService`).
  ///
  /// [purchaseDate] est purement informative (hotfix_142) : elle ne crée
  /// aucune écriture de dépense — le coût matières est compté à la vente.
  static Future<Ingredient> create({
    required String shopId,
    required String name,
    String unit = 'pièce',
    int costPerUnit = 0,
    double quantity = 0,
    double alertThreshold = 0,
    DateTime? purchaseDate,
  }) async {
    final ing = Ingredient(
      id: _id(),
      shopId: shopId,
      name: name.trim(),
      unit: unit,
      costPerUnit: costPerUnit,
      quantity: quantity,
      alertThreshold: alertThreshold,
      purchaseDate: purchaseDate,
      createdAt: DateTime.now(),
    );
    await _put(ing);
    return ing;
  }

  static Future<void> update(Ingredient ing) => _put(ing);

  static Future<void> _put(Ingredient ing) async {
    final map = ing.toMap();
    try {
      await _raw().put(ing.id, map);
    } catch (e) {
      debugPrint('[Ingredient] put Hive err: $e');
    }
    AppDatabase.bgUpsert('ingredients', map);
    AppDatabase.notifyListeners('ingredients', ing.shopId);
  }

  static Future<void> delete(String id, String shopId) async {
    try {
      await _raw().delete(id);
    } catch (e) {
      debugPrint('[Ingredient] delete Hive err: $e');
    }
    AppDatabase.bgDelete('ingredients', val: id);
    AppDatabase.notifyListeners('ingredients', shopId);
  }

  // ── Réception ───────────────────────────────────────────────────────────

  /// Entre [quantity] en stock et réévalue le coût unitaire en MOYENNE
  /// PONDÉRÉE avec ce qui s'y trouvait déjà.
  ///
  /// C'est ce qui évite de saisir le prix deux fois — une fois à la réception,
  /// une fois dans la fiche de l'ingrédient. Deux valeurs à tenir à jour
  /// manuellement finissent toujours par diverger.
  ///
  /// Retourne l'ingrédient réévalué, `null` s'il a disparu entre-temps.
  static Future<Ingredient?> receive(
    String shopId,
    String id, {
    required double quantity,
    int amountPaid = 0,
  }) async {
    if (quantity <= 0) return byId(shopId, id);
    // Relecture juste avant écriture : entre l'ouverture de la feuille et sa
    // validation, un autre appareil a pu changer le stock ou le seuil, et un
    // copyWith sur un objet périmé les écraserait.
    final fresh = byId(shopId, id);
    if (fresh == null) return null;

    final next = fresh.copyWith(
      quantity: fresh.quantity + quantity,
      costPerUnit: weightedUnitCost(
        currentQty: fresh.quantity,
        currentUnitCost: fresh.costPerUnit,
        receivedQty: quantity,
        amountPaid: amountPaid,
      ),
    );
    await _put(next);
    return next;
  }

  /// COÛT MOYEN PONDÉRÉ après une entrée de marchandise :
  ///
  /// ```
  ///        valeur du stock existant + montant payé
  ///        ───────────────────────────────────────
  ///          quantité existante + quantité reçue
  /// ```
  ///
  /// Un montant à ZÉRO laisse le coût INCHANGÉ, il ne le dilue pas. Zéro ne
  /// veut pas dire « reçu gratuitement » mais « montant non renseigné » — la
  /// feuille de réception le dit explicitement. Diluer sur une information
  /// absente ferait baisser le coût unitaire à chaque réception mal saisie, et
  /// sous-évaluerait silencieusement les pertes d'inventaire.
  ///
  /// Publique à dessein : la feuille de réception l'appelle pour ANNONCER le
  /// nouveau coût avant validation. Une valeur qui chiffre les pertes
  /// d'inventaire ne doit pas changer à l'insu de celui qui la provoque.
  static int weightedUnitCost({
    required double currentQty,
    required int currentUnitCost,
    required double receivedQty,
    required int amountPaid,
  }) {
    if (amountPaid <= 0) return currentUnitCost;
    if (receivedQty <= 0) return currentUnitCost;
    final existingQty = currentQty > 0 ? currentQty : 0;
    final total = existingQty + receivedQty;
    if (total <= 0) return currentUnitCost;
    final value = existingQty * currentUnitCost + amountPaid;
    return (value / total).round();
  }

  // ── Régularisation des achats non enregistrés ───────────────────────────
  //
  // Les ingrédients créés avant que le formulaire n'écrive une dépense portent
  // un stock et un coût unitaire, mais aucun franc ne leur est rattaché. Leurs
  // plats affichent donc 0 F de coût matières : la répartition n'a rien à
  // répartir. Ces deux fonctions rattrapent ce passé.

  /// Ingrédients ayant du stock ET un coût unitaire, mais dont aucun achat
  /// n'a jamais été enregistré en dépense.
  ///
  /// Le filtre sur la dépense EXISTANTE est ce qui rend la régularisation
  /// rejouable sans risque : la relancer deux fois ne double aucun montant.
  static List<Ingredient> withoutRecordedPurchase(String shopId) {
    final linked = <String>{};
    try {
      for (final e in DailyExpenseService.forShop(shopId)) {
        final id = e.ingredientId;
        if (id != null && id.isNotEmpty) linked.add(id);
      }
    } catch (e) {
      // En cas de doute on ne propose RIEN : mieux vaut ne pas régulariser que
      // créer des doublons de dépenses.
      debugPrint('[Ingredient] lecture dépenses err: $e');
      return const [];
    }
    return forShop(shopId)
        .where((i) =>
            i.quantity > 0 && i.costPerUnit > 0 && !linked.contains(i.id))
        .toList();
  }

  /// Montant qu'une régularisation écrirait pour cet ingrédient : la valeur du
  /// stock qu'il déclare détenir.
  static int backfillAmountFor(Ingredient i) =>
      (i.quantity * i.costPerUnit).round();

  /// Ids des ingrédients auxquels AUCUN franc n'est rattaché.
  ///
  /// C'est le défaut le plus coûteux du module, et le plus silencieux : un
  /// ingrédient sans dépense ne pèse RIEN dans la répartition, donc les plats
  /// qui le contiennent affichent un coût matières minoré et une marge
  /// flatteuse. Rien à l'écran ne le signalait.
  ///
  /// Deux façons d'y tomber :
  ///   * l'ingrédient est créé À LA VOLÉE depuis la fiche d'un plat, où le
  ///     formulaire ne demande que le nom et l'unité ;
  ///   * il a été créé avec une quantité et un prix, mais avant que le
  ///     formulaire n'écrive la dépense correspondante.
  ///
  /// Le premier cas n'est PAS régularisable automatiquement — il n'y a aucun
  /// montant à reprendre, il faut une réception. Le second l'est, et c'est
  /// exactement [withoutRecordedPurchase], qui n'est donc qu'un sous-ensemble
  /// de cette liste-ci.
  ///
  /// Renvoie un ensemble : la liste des ingrédients se parcourt en boucle, un
  /// `contains` sur une liste rendrait ce parcours quadratique.
  static Set<String> withoutCostData(String shopId) {
    final linked = <String>{};
    try {
      for (final e in DailyExpenseService.forShop(shopId)) {
        final id = e.ingredientId;
        if (id != null && id.isNotEmpty) linked.add(id);
      }
    } catch (e) {
      // En cas de doute on ne signale RIEN : un faux avertissement sur tous
      // les ingrédients serait pire que pas d'avertissement du tout.
      debugPrint('[Ingredient] lecture dépenses err: $e');
      return const {};
    }
    return {
      for (final i in forShop(shopId))
        if (!linked.contains(i.id)) i.id,
    };
  }

  /// Écrit une dépense par ingrédient de [withoutRecordedPurchase].
  ///
  /// Deux choix qui comptent :
  ///   * la dépense est datée du jour d'ACHAT déclaré (à défaut, de la création
  ///     de l'ingrédient) — pas d'aujourd'hui. Antidater est fidèle : l'argent
  ///     est sorti à ce moment-là. Conséquence à connaître : le coût sera
  ///     imputé aux plats vendus CE MOIS-LÀ, pas au mois courant ;
  ///   * elle est marquée HORS ESPÈCES. Ces achats ont été payés il y a
  ///     longtemps ; les compter comme sorties du tiroir ferait apparaître un
  ///     manquant massif à la prochaine clôture de caisse.
  static Future<({int count, int total})> recordMissingPurchases(
      String shopId) async {
    var count = 0, total = 0;
    for (final i in withoutRecordedPurchase(shopId)) {
      final amount = backfillAmountFor(i);
      if (amount <= 0) continue;
      try {
        await DailyExpenseService.record(
          shopId: shopId,
          description: '${i.name} — achat régularisé',
          amount: amount,
          kind: ExpenseKind.achatMarche,
          ingredientId: i.id,
          isCash: false,
          date: i.purchaseDate ?? i.createdAt,
        );
        count++;
        total += amount;
      } catch (e) {
        // Un ingrédient qui échoue n'empêche pas les autres d'être régularisés.
        debugPrint('[Ingredient] régularisation err (${i.name}): $e');
      }
    }
    return (count: count, total: total);
  }

  /// Décrémente le stock d'un ingrédient de [amount] (jamais sous 0).
  static Future<void> consume(
      String shopId, String ingredientId, double amount) async {
    if (amount <= 0) return;
    final ing = byId(shopId, ingredientId);
    if (ing == null) return;
    final next = ing.quantity - amount;
    await _put(ing.copyWith(quantity: next < 0 ? 0 : next));
  }
}
