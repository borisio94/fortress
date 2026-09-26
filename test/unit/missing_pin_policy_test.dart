// Rien n'invitait jamais à définir le code PIN gérant.
//
// Trois gestes laissent l'argent sortir sans qu'un plat sorte : annuler une
// tournée partie en cuisine, remiser une addition, défaire une vente
// encaissée. `ManagerGate` les couvre — mais seulement si un PIN existe. Sans
// PIN, l'action passe avec un `AppSnack.info` qui renvoie chercher
// « Réglages → Sécurité » à la main.
//
// Une boutique neuve n'a pas de PIN. Elle restait donc indéfiniment dans cet
// état, et le seul signal tombait APRÈS que l'argent soit sorti.
//
// ON NE BLOQUE PAS, et ce n'est pas un compromis : refuser une annulation en
// plein service parce qu'un réglage manque paralyserait la salle, et le
// personnel contournerait par un chemin non tracé — exactement ce qu'on
// cherche à éviter. C'est le même raisonnement que le contrôle de longueur
// retiré de l'écran de connexion : un correctif de sécurité qui verrouille
// n'est pas un correctif.
//
// CE QUI CHANGE : au moment où la porte est franchie, on PROPOSE au
// propriétaire de poser le code, sur-le-champ, sans navigation. Il accepte ou
// non ; l'action continue dans les deux cas.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/permisions/missing_pin_policy.dart';

void main() {
  group('À qui propose-t-on de définir le code', () {
    test('AU PROPRIÉTAIRE, au moment où la porte est franchie', () {
      // LE test de ce lot. C'est le seul instant où l'on sait que la
      // protection servirait à quelque chose : l'argent est en train de
      // sortir. Une bannière de plus sur un tableau de bord se balaie.
      expect(missingPinResponse(isShopOwner: true),
          MissingPinResponse.offerSetup);
    });

    test('ET À PERSONNE D\'AUTRE — on ne dit rien à un délégué', () {
      // `PinService` pousse le code sur `profiles` : c'est le PIN DU
      // PROPRIÉTAIRE, pas un code d'établissement. Le proposer à un gérant
      // délégué lui ferait poser le code de quelqu'un d'autre.
      //
      // Et le message actuel — « cette action n'est pas protégée » — lui
      // apprend que la porte est ouverte sans qu'il puisse la fermer. C'est
      // le seul usage qu'il peut en faire.
      expect(missingPinResponse(isShopOwner: false),
          MissingPinResponse.staySilent);
    });

    test('la réponse ne dépend QUE de la propriété', () {
      // Deux valeurs, deux réponses, rien d'autre. Si un troisième cas
      // apparaît un jour, il devra être écrit ici et pas déduit sur place.
      final seen = <MissingPinResponse>{
        for (final owner in [true, false])
          missingPinResponse(isShopOwner: owner),
      };
      expect(seen.length, 2);
    });
  });

  group('Ce que la règle ne fait pas', () {
    test('AUCUNE DES DEUX RÉPONSES NE BLOQUE', () {
      // L'invariant qui protège le raisonnement d'origine. Le jour où
      // quelqu'un voudra « durcir » en ajoutant un `refuse`, ce test tombera
      // et l'obligera à relire pourquoi on ne bloque pas.
      for (final r in MissingPinResponse.values) {
        expect(r == MissingPinResponse.offerSetup
                || r == MissingPinResponse.staySilent,
            isTrue,
            reason: '$r — une réponse qui bloque a été ajoutée');
      }
      expect(MissingPinResponse.values.length, 2);
    });
  });
}
