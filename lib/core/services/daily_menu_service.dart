import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;

import '../storage/hive_boxes.dart';
import '../../features/caisse/domain/entities/sale_item.dart';

/// État de disponibilité d'un plat pour la journée en cours.
class DailyAvailability {
  /// Le plat est-il proposé aujourd'hui ? (interrupteur admin)
  final bool enabled;

  /// Stock du jour restant. `null` = illimité (aucune limite fixée).
  final int? count;

  const DailyAvailability({required this.enabled, required this.count});

  /// Défaut quand rien n'est configuré pour aujourd'hui : proposé, sans limite.
  static const initial = DailyAvailability(enabled: true, count: null);

  /// Vrai si le plat peut être commandé maintenant.
  bool get isAvailable => enabled && (count == null || count! > 0);

  /// Indisponible parce que le stock du jour est épuisé (distinct d'une
  /// désactivation manuelle) — permet de choisir le libellé « Épuisé ».
  bool get isSoldOut => enabled && count != null && count! <= 0;
}

/// CE QU'UN DÉCRÉMENT DU JOUR A RÉELLEMENT FAIT.
///
/// Rien ne le disait. `consume` rabotait à zéro — `next < 0 ? 0 : next` — et
/// `_write` avalait un refus de Hive dans un `debugPrint` : trois portions
/// restantes, une commande de cinq, on écrivait 0 et personne n'apprenait
/// qu'on en avait vendu deux de trop.
///
/// Le `try/catch` qui entourait l'appel, lui, était du code mort : `read` et
/// `_write` ne lèvent jamais, donc `consumeForOrder` non plus. On cherchait
/// une exception là où il n'y en avait aucune ; la perte était dans le rabot.
class DailyConsumeReport {
  /// Plat par plat, ce qui a été vendu AU-DELÀ du stock du jour.
  final Map<String, int> oversold;

  /// Toutes les écritures ont-elles été acceptées par Hive ?
  final bool allStored;

  const DailyConsumeReport({required this.oversold, required this.allStored});

  static const clean =
      DailyConsumeReport(oversold: <String, int>{}, allStored: true);

  /// Rien à signaler : aucun dépassement, aucune écriture perdue.
  bool get isClean => oversold.isEmpty && allStored;

  /// Total des portions vendues au-delà du décompte, tous plats confondus.
  int get totalOversold => oversold.values.fold(0, (s, v) => s + v);
}

/// Ce que le serveur doit lire, ou `null` si tout s'est bien passé.
///
/// LES PLATS SONT NOMMÉS, pas identifiés : `oversold` est indexé par
/// identifiant de produit, illisible pour qui tient un plateau. Les noms
/// viennent des lignes de la commande, qui les portent déjà figés.
///
/// Deux pertes distinctes, deux phrases : un dépassement du décompte dit
/// d'aller vérifier la réserve ; une écriture refusée dit que le décompte de
/// la journée est faux à partir de maintenant. Les confondre enverrait
/// compter des portions dans le premier cas comme dans le second.
String? oversoldMessage(DailyConsumeReport report, List<SaleItem> items) {
  if (report.isClean) return null;

  if (report.oversold.isEmpty) {
    return 'Décompte du jour non enregistré : les quantités restantes ne sont '
        'plus fiables.';
  }

  final names = <String>[];
  for (final entry in report.oversold.entries) {
    final line = items.where((i) => i.productId == entry.key);
    final name = line.isEmpty ? entry.key : line.first.productName;
    names.add('$name (${entry.value})');
  }

  final total = report.totalOversold;
  final head = total > 1
      ? '$total portions vendues au-delà du stock du jour'
      : '1 portion vendue au-delà du stock du jour';
  final tail = report.allStored
      ? ''
      : ' — et le décompte n\'a pas pu être enregistré';
  return '$head : ${names.join(', ')}.$tail';
}

/// Ce qui MANQUE quand on retire [qty] d'un décompte de [count].
///
/// `null` = aucune limite fixée, donc aucun manque possible : le plat ne
/// décrémente pas (cf. `consume`). Zéro quand tout passe.
///
/// Séparé du décrément lui-même pour être vérifiable sans Hive : c'est
/// l'arithmétique qui perdait l'information, pas le stockage.
int shortfallOf({required int? count, required int qty}) {
  if (count == null) return 0;
  final missing = qty - count;
  return missing > 0 ? missing : 0;
}

/// Disponibilités du jour de la carte d'un restaurant (LOCAL, par appareil).
///
/// Chaque matin l'admin (ré)active les plats du jour et peut fixer un stock.
/// Le stock décrémente à chaque commande ; à 0 le plat passe « épuisé ». Les
/// réglages se réinitialisent chaque jour : une entrée dont la `date` n'est
/// pas aujourd'hui est ignorée → retour au défaut « proposé / illimité ».
///
/// Volontairement NON synchronisé (état opérationnel d'un poste de service) :
/// ni table Supabase ni file offline — c'est le poste qui tient le compte de
/// sa journée. Si un besoin multi-postes apparaît, migrer vers le pattern
/// AppDatabase.sync<Entity> (cf. CLAUDE.md).
class DailyMenuService {
  DailyMenuService._();

  /// Incrémenté à CHAQUE écriture (dispo, stock, décrément à la commande).
  /// Les écrans qui affichent la dispo (carte Menu) l'écoutent pour se
  /// reconstruire immédiatement, sans attendre une autre interaction — utile
  /// quand le décrément vient d'une commande encaissée depuis le panier.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String _key(String shopId, String productId) => '$shopId::$productId';

  static String _today() {
    final n = DateTime.now();
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return '${n.year}-$m-$d';
  }

  /// Lit l'état du jour pour un plat (défaut si absent ou périmé = veille).
  static DailyAvailability read(String shopId, String productId) {
    try {
      final raw =
          HiveBoxes.dailyMenuAvailabilityBox.get(_key(shopId, productId));
      if (raw == null) return DailyAvailability.initial;
      final m = Map<String, dynamic>.from(raw);
      // Réinit quotidienne : une entrée d'hier ne s'applique plus.
      if (m['date'] != _today()) return DailyAvailability.initial;
      return DailyAvailability(
        enabled: (m['enabled'] as bool?) ?? true,
        count: (m['count'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('[DailyMenu] read err: $e');
      return DailyAvailability.initial;
    }
  }

  /// Écrit l'état du jour. Rend `false` si Hive a refusé la ligne.
  ///
  /// L'issue était perdue : le `catch` se contentait d'un `debugPrint`, donc un
  /// décrément refusé disparaissait sans laisser de trace et sans même réveiller
  /// les écrans. Les appelants qui annoncent quelque chose à l'utilisateur
  /// doivent pouvoir le savoir — même convention que `RestaurantTableService`.
  static Future<bool> _write(
      String shopId, String productId, DailyAvailability a) async {
    try {
      await HiveBoxes.dailyMenuAvailabilityBox
          .put(_key(shopId, productId), <String, dynamic>{
        'date': _today(),
        'enabled': a.enabled,
        'count': a.count,
      });
      // Réveille les écrans qui affichent la dispo (rebuild immédiat).
      revision.value++;
      return true;
    } catch (e) {
      debugPrint('[DailyMenu] write err: $e');
      return false;
    }
  }

  /// Active / désactive le plat pour aujourd'hui.
  static Future<void> setEnabled(
      String shopId, String productId, bool enabled) async {
    final cur = read(shopId, productId);
    await _write(
        shopId, productId, DailyAvailability(enabled: enabled, count: cur.count));
  }

  /// Fixe le stock du jour. `null` = illimité (retire toute limite). Une
  /// valeur négative est ramenée à 0.
  static Future<void> setCount(
      String shopId, String productId, int? count) async {
    final cur = read(shopId, productId);
    final c = (count != null && count < 0) ? 0 : count;
    await _write(
        shopId, productId, DailyAvailability(enabled: cur.enabled, count: c));
  }

  /// Décrémente le stock du jour d'un plat de [qty] (jamais sous 0). No-op si
  /// aucune limite n'est fixée (count == null = illimité).
  ///
  /// Rend ce qui MANQUE et si l'écriture a tenu. Le rabot à zéro reste — on ne
  /// va pas inventer un stock négatif — mais il ne se fait plus en silence :
  /// c'est l'appelant qui décide quoi en dire.
  static Future<({int shortfall, bool stored})> consume(
      String shopId, String productId, int qty) async {
    final cur = read(shopId, productId);
    if (cur.count == null) return (shortfall: 0, stored: true);
    final missing = shortfallOf(count: cur.count, qty: qty);
    final next = cur.count! - qty;
    final stored = await _write(shopId, productId,
        DailyAvailability(enabled: cur.enabled, count: next < 0 ? 0 : next));
    return (shortfall: missing, stored: stored);
  }

  /// Applique le décrément à toutes les lignes d'une commande restaurant —
  /// appelé après l'enregistrement d'une vente (cf. CaisseBloc).
  ///
  /// Rend le bilan de l'opération. Il vaut [DailyConsumeReport.clean] dans le
  /// cas courant ; tout ce qui s'en écarte doit être DIT, parce que personne
  /// d'autre ne le verra : ce décompte est local à l'appareil et ne remonte
  /// nulle part.
  ///
  /// Les lignes sont CUMULÉES par plat : une commande peut porter deux fois le
  /// même plat, et deux manques de 1 valent un manque de 2.
  static Future<DailyConsumeReport> consumeForOrder(
      String shopId, List<SaleItem> items) async {
    final oversold = <String, int>{};
    var allStored = true;
    for (final it in items) {
      final pid = it.productId;
      if (pid.isEmpty) continue;
      final r = await consume(shopId, pid, it.quantity);
      if (r.shortfall > 0) {
        oversold[pid] = (oversold[pid] ?? 0) + r.shortfall;
      }
      if (!r.stored) allStored = false;
    }
    return DailyConsumeReport(oversold: oversold, allStored: allStored);
  }
}
