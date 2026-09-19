// Vérifie qu'une modification de prix d'un article du panier qui ré-saisit
// LE MÊME prix que le prix de base est IGNORÉE : `customPrice` reste null,
// donc l'article n'est pas marqué « prix modifié » (pas de badge / pas
// d'alerte de marge). Un prix réellement différent est bien enregistré.
//
// `CaisseBloc()` n'a aucune dépendance ; `_onAdd` / `_onUpdatePrice` sont des
// mutations d'état pures → testables sans Hive ni Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/caisse/domain/entities/sale_item.dart';
import 'package:fortress/features/caisse/presentation/bloc/caisse_bloc.dart';

void main() {
  late CaisseBloc bloc;

  setUp(() {
    bloc = CaisseBloc();
    bloc.add(AddItemToCart(const SaleItem(
      productId: 'p1',
      productName: 'Article',
      unitPrice: 5000,
      quantity: 1,
    )));
  });

  tearDown(() => bloc.close());

  SaleItem item() => bloc.state.items.firstWhere((i) => i.productId == 'p1');

  test('même prix que le prix de base → modification ignorée (customPrice null)',
      () async {
    bloc.add(UpdateItemPrice('p1', 5000));
    await pumpEventQueue();
    expect(item().customPrice, isNull);
    expect(item().effectivePrice, 5000);
    expect(item().isPriceAlertTriggered, isFalse);
  });

  test('prix différent → enregistré comme prix modifié', () async {
    bloc.add(UpdateItemPrice('p1', 4000));
    await pumpEventQueue();
    expect(item().customPrice, 4000);
    expect(item().effectivePrice, 4000);
  });

  test('repasser au prix de base après une modif → réinitialise à null',
      () async {
    bloc.add(UpdateItemPrice('p1', 4000));
    await pumpEventQueue();
    expect(item().customPrice, 4000);

    bloc.add(UpdateItemPrice('p1', 5000)); // = prix de base
    await pumpEventQueue();
    expect(item().customPrice, isNull);
  });

  test('null → réinitialise au prix original', () async {
    bloc.add(UpdateItemPrice('p1', 4000));
    await pumpEventQueue();
    bloc.add(UpdateItemPrice('p1', null));
    await pumpEventQueue();
    expect(item().customPrice, isNull);
    expect(item().effectivePrice, 5000);
  });
}
