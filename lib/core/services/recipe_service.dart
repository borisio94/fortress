import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:hive_flutter/hive_flutter.dart';

import '../../features/restaurant/domain/entities/recipe_ingredient.dart';
import '../database/app_database.dart';
import '../storage/hive_boxes.dart';
import 'ingredient_service.dart';

/// Service Hive-first de la COMPOSITION des plats : quels ingrédients entrent
/// dans quel plat, et avec quelle générosité de portion.
///
/// AUCUNE QUANTITÉ n'est stockée ni demandée — c'est le choix de méthode du
/// module. Le coût matières d'un plat n'est pas calculé ici : il est réparti a
/// posteriori entre les plats, au prorata des ventes, par
/// `IngredientAllocationService`.
///
/// Ids `ri_` + microsecondes. Push Supabase via `bgUpsert('recipe_ingredients')`.
class RecipeService {
  RecipeService._();

  static Box<Map> _raw() => HiveBoxes.recipeIngredientsBox;

  static String _id() => 'ri_${DateTime.now().microsecondsSinceEpoch}';

  /// TOUS les liens de la boutique — lus en une passe par le moteur de
  /// répartition, qui ne doit pas rescanner la boîte pour chaque ingrédient.
  static List<RecipeIngredient> forShop(String shopId) {
    try {
      final list = <RecipeIngredient>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        try {
          list.add(RecipeIngredient.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      return list;
    } catch (e) {
      debugPrint('[Recipe] forShop err: $e');
      return [];
    }
  }

  /// Ingrédients composant un plat.
  static List<RecipeIngredient> forProduct(String shopId, String productId) {
    try {
      final list = <RecipeIngredient>[];
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        if (raw['product_id']?.toString() != productId) continue;
        try {
          list.add(RecipeIngredient.fromMap(Map<String, dynamic>.from(raw)));
        } catch (_) {/* ligne corrompue : ignorée */}
      }
      return list;
    } catch (e) {
      debugPrint('[Recipe] forProduct err: $e');
      return [];
    }
  }

  /// Nombre de plats VIVANTS et distincts qui utilisent cet ingrédient — base
  /// du prorata de coût partagé et de la maintenance du type
  /// specialized/shared.
  ///
  /// Les plats supprimés sont exclus. La suppression d'un plat est un
  /// soft-delete réversible et ne touche PAS ses lignes de recette (restaurer
  /// le plat doit restaurer sa recette) — mais compter ces lignes divisait le
  /// coût d'un ingrédient partagé par des plats fantômes, et sous-estimait
  /// donc le coût matières de tous les autres plats qui l'utilisent.
  static int dishCountForIngredient(String shopId, String ingredientId) {
    final products = <String>{};
    for (final raw in _raw().values) {
      if (raw['shop_id']?.toString() != shopId) continue;
      if (raw['ingredient_id']?.toString() != ingredientId) continue;
      final pid = raw['product_id']?.toString();
      if (pid == null || pid.isEmpty) continue;
      if (!_isLiveProduct(pid)) continue;
      products.add(pid);
    }
    return products.length;
  }

  /// Ids des ingrédients qu'AU MOINS UN plat vivant contient.
  ///
  /// UN SEUL PASSAGE, contrairement à [dishCountForIngredient] qui balaye la
  /// boîte entière pour un seul ingrédient. Une liste de N ingrédients
  /// l'appellerait N fois ; ici l'écran la calcule une fois et chaque ligne
  /// interroge l'ensemble en temps constant.
  ///
  /// Même filtre que [dishCountForIngredient] : les plats supprimés sont
  /// exclus. Sans ça, un ingrédient rattaché à un plat effacé passerait pour
  /// rattaché alors que plus rien ne le consomme.
  ///
  /// N'ALTÈRE AUCUN CALCUL — c'est une lecture, ajoutée le 21/09/2026 pour
  /// signaler à l'écran les ingrédients qu'aucune recette ne reprend.
  ///
  /// Rend `null` si la boîte est illisible, et JAMAIS un ensemble vide dans ce
  /// cas : les deux se ressemblent et ne disent pas la même chose. Un ensemble
  /// vide signifie « aucun ingrédient n'est rattaché », ce qui ferait afficher
  /// l'avertissement sur toute la liste et enverrait le gérant corriger ce qui
  /// va bien. `null` signifie « je ne sais pas » — l'écran se tait.
  static Set<String>? linkedIngredientIds(String shopId) {
    final out = <String>{};
    try {
      for (final raw in _raw().values) {
        if (raw['shop_id']?.toString() != shopId) continue;
        final ing = raw['ingredient_id']?.toString();
        if (ing == null || ing.isEmpty) continue;
        if (out.contains(ing)) continue;
        final pid = raw['product_id']?.toString();
        if (pid == null || pid.isEmpty) continue;
        if (!_isLiveProduct(pid)) continue;
        out.add(ing);
      }
    } catch (e) {
      debugPrint('[Recipe] linkedIngredientIds err: $e');
      return null;
    }
    return out;
  }

  /// Le plat existe-t-il encore, non supprimé ?
  ///
  /// Lecture RAW volontaire : seul `deleted_at` est utile ici, et
  /// désérialiser le produit entier (variantes + migrations de schéma) coûte
  /// bien plus cher dans une boucle de calcul de coût — cette fonction est
  /// appelée pour chaque ligne partagée de chaque plat du reporting.
  static bool _isLiveProduct(String productId) {
    try {
      return isLiveProductMap(HiveBoxes.productsBox.get(productId));
    } catch (e) {
      // Box indisponible : on garde le comportement historique (le plat
      // compte) plutôt que de basculer tout le catalogue en « spécialisé ».
      debugPrint('[Recipe] lecture produit err: $e');
      return true;
    }
  }

  /// Règle « plat vivant » sous forme pure, sans accès Hive : map absente =
  /// plat inexistant (jamais synchronisé, ou purgé), `deleted_at` renseigné =
  /// plat supprimé.
  @visibleForTesting
  static bool isLiveProductMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return false;
    final deleted = raw['deleted_at'];
    return deleted == null || deleted.toString().isEmpty;
  }

  /// Déclare qu'un plat CONTIENT un ingrédient (ou change la générosité de sa
  /// portion si le lien existe déjà — un seul lien par couple plat/ingrédient).
  ///
  /// Aucune quantité : c'est tout l'intérêt de la méthode. [portionWeight] dit
  /// seulement si la part est petite, normale ou grande.
  /// [quantity] / [unit] / [quantityConfirmed] ne servent QU'À la méthode
  /// fiche technique. `quantity` à `null` laisse la valeur existante
  /// intacte — la répartition au prorata n'a rien à en dire, et écraser à
  /// zéro depuis un écran qui n'affiche pas le champ effacerait en silence
  /// des fiches que quelqu'un a pesées.
  static Future<void> addLink({
    required String shopId,
    required String productId,
    required String ingredientId,
    double portionWeight = RecipeIngredient.normalPortion,
    double? quantity,
    String? unit,
    bool? quantityConfirmed,
  }) async {
    final existing = forProduct(shopId, productId)
        .where((l) => l.ingredientId == ingredientId)
        .toList();
    final RecipeIngredient line;
    if (existing.isNotEmpty) {
      line = existing.first.copyWith(
        portionWeight: portionWeight,
        quantity: quantity,
        unit: unit,
        quantityConfirmed: quantityConfirmed,
      );
    } else {
      line = RecipeIngredient(
        id: _id(),
        shopId: shopId,
        productId: productId,
        ingredientId: ingredientId,
        portionWeight: portionWeight,
        quantity: quantity ?? 0,
        unit: unit ?? '',
        quantityConfirmed: quantityConfirmed ?? false,
        createdAt: DateTime.now(),
      );
    }
    await _put(line);
    await _refreshIngredientType(shopId, ingredientId);
  }

  static Future<void> removeLine(RecipeIngredient line) async {
    try {
      await _raw().delete(line.id);
    } catch (e) {
      debugPrint('[Recipe] delete Hive err: $e');
    }
    AppDatabase.bgDelete('recipe_ingredients', val: line.id);
    AppDatabase.notifyListeners('recipe_ingredients', line.shopId);
    await _refreshIngredientType(line.shopId, line.ingredientId);
  }

  static Future<void> _put(RecipeIngredient line) async {
    final map = line.toMap();
    try {
      await _raw().put(line.id, map);
    } catch (e) {
      debugPrint('[Recipe] put Hive err: $e');
    }
    AppDatabase.bgUpsert('recipe_ingredients', map);
    AppDatabase.notifyListeners('recipe_ingredients', line.shopId);
  }

  /// Ajuste l'ÉTIQUETTE de l'ingrédient : 'shared' dès ≥ 2 plats l'utilisent,
  /// 'specialized' sinon. Évite une écriture inutile si le type est déjà bon.
  ///
  /// Étiquette d'affichage seulement : depuis la répartition au prorata, elle
  /// n'a plus aucun effet sur un montant. Un ingrédient dans 5 plats se
  /// répartit entre 5 plats parce qu'il y est lié, pas parce qu'il est marqué
  /// « partagé ».
  static Future<void> _refreshIngredientType(
      String shopId, String ingredientId) async {
    final ing = IngredientService.byId(shopId, ingredientId);
    if (ing == null) return;
    final wanted =
        dishCountForIngredient(shopId, ingredientId) >= 2 ? 'shared' : 'specialized';
    if (ing.type != wanted) {
      await IngredientService.update(ing.copyWith(type: wanted));
    }
  }

  // ── Coût matières ───────────────────────────────────────────────────────
  //
  // Il n'est PAS calculé ici, et c'est délibéré : sans quantité par plat, le
  // coût d'un ingrédient ne peut pas être imputé plat par plat au moment où on
  // regarde la fiche. Il se répartit a posteriori, au prorata de ce qui s'est
  // vendu sur une période — voir `IngredientAllocationService`.
  //
  // Conséquence directe : le coût d'un plat DÉPEND D'UNE PÉRIODE. Toute
  // fonction qui prétendrait rendre « le » coût d'un plat sans en préciser une
  // mentirait.

  // ── Décrément à la vente : SUPPRIMÉ ─────────────────────────────────────
  //
  // Vendre un plat ne retire plus rien du stock des ingrédients. Sans quantité
  // par plat, il n'y a tout simplement rien à retirer : l'app ignore combien de
  // grammes de poulet part dans une assiette.
  //
  // Le stock d'un ingrédient ne bouge donc plus que par deux gestes explicites :
  // la RÉCEPTION (on ajoute ce qu'on vient d'acheter) et le COMPTAGE
  // d'inventaire (on corrige à ce qu'on voit en réserve). C'est la contrepartie
  // assumée d'une saisie sans pesée.
}
