// On déconnectait quelqu'un dont la session était valide.
//
// Le parcours d'inscription se termine par « Démarrer mon essai 14 jours ».
// Le compte est créé, la boutique est créée, la session est ouverte — et
// l'application déconnecte, affiche « Connectez-vous pour commencer » et
// renvoie sur l'écran de connexion. L'utilisateur ressaisit les identifiants
// qu'il a choisis trente secondes plus tôt. C'est son premier contact.
//
// LA RAISON ÉTAIT BONNE. L'essai de 14 jours est créé par le déclencheur SQL
// `create_trial_subscription` à l'insertion de la ligne `shops`. Enchaîner
// directement appelait parfois `get_user_plan` AVANT que l'essai y soit
// visible, et le compte neuf tombait sur un paywall « Expiré » — le pire
// accueil possible. La déconnexion l'évitait.
//
// LE REMÈDE ÉTAIT TROP LARGE. Ce qu'il fallait, c'est redemander : un essai
// pas encore visible le devient en quelques centaines de millisecondes. Celui
// qui ne le devient jamais signale autre chose — une table `plans` sans ligne
// `trial` — et là, renvoyer au login est la bonne réponse.
//
// Ces tests portent sur la DÉCISION, pas sur l'appel réseau : combien de fois
// on redemande, à quel rythme, et ce qu'on fait au bout.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/auth/domain/post_signup_entry.dart';

void main() {
  group('Ce qu\'on fait après la création de la boutique', () {
    test('UN ESSAI VISIBLE FAIT ENTRER DANS L\'APPLICATION', () {
      // LE test de ce lot. C'est le cas courant — le déclencheur a fait son
      // travail, le plan est là, la session est valide. Rien ne justifie de
      // renvoyer quelqu'un saisir un mot de passe qu'il vient de choisir.
      expect(postSignUpOutcome(trialVisible: true, attempt: 0),
          PostSignUpOutcome.enter);
    });

    test('un essai pas encore visible fait PATIENTER, pas renoncer', () {
      // La course de réplication. Elle se résout d'elle-même ; renoncer à la
      // première lecture, c'est ce que faisait la déconnexion forcée.
      expect(postSignUpOutcome(trialVisible: false, attempt: 0),
          PostSignUpOutcome.retry);
      expect(
          postSignUpOutcome(
              trialVisible: false, attempt: kTrialLookupAttempts - 1),
          PostSignUpOutcome.retry);
    });

    test('au bout des tentatives, on renonce — et c\'est l\'ancien chemin', () {
      // Ce n'est pas un repli de confort : un essai qui n'arrive jamais veut
      // dire que quelque chose manque côté serveur. Le login relit le plan
      // depuis zéro, et le paywall qu'on verrait alors serait mérité.
      expect(
          postSignUpOutcome(trialVisible: false, attempt: kTrialLookupAttempts),
          PostSignUpOutcome.signOutAndAskLogin);
      expect(
          postSignUpOutcome(
              trialVisible: false, attempt: kTrialLookupAttempts + 3),
          PostSignUpOutcome.signOutAndAskLogin);
    });

    test('un essai visible l\'emporte sur le compteur de tentatives', () {
      // Sinon la dernière lecture, celle qui réussit enfin, serait jetée.
      expect(
          postSignUpOutcome(
              trialVisible: true, attempt: kTrialLookupAttempts + 10),
          PostSignUpOutcome.enter);
    });
  });

  group('Ce qui rend un essai visible', () {
    test('il faut un plan ET qu\'il soit actif', () {
      expect(trialIsVisible(hasPlan: true, isActive: true), isTrue);
    });

    test('un plan expiré ne compte pas', () {
      // C'est exactement ce que le paywall affichait : `hasPlan` était vrai,
      // le plan était `expired`. Se contenter de `hasPlan` rouvrirait le
      // défaut que la déconnexion forcée avait été posée pour éviter.
      expect(trialIsVisible(hasPlan: true, isActive: false), isFalse);
    });

    test('aucun plan du tout ne compte pas non plus', () {
      expect(trialIsVisible(hasPlan: false, isActive: false), isFalse);
      expect(trialIsVisible(hasPlan: false, isActive: true), isFalse);
    });
  });

  group('Le rythme des tentatives', () {
    test('le délai croît, puis se plafonne', () {
      expect(trialLookupDelay(0), const Duration(milliseconds: 250));
      expect(trialLookupDelay(1), const Duration(milliseconds: 500));
      expect(trialLookupDelay(2), const Duration(seconds: 1));
      expect(trialLookupDelay(3), kTrialLookupMaxDelay);
      expect(trialLookupDelay(9), kTrialLookupMaxDelay);
    });

    test('L\'ATTENTE TOTALE EST BORNÉE, et tient sous six secondes', () {
      // Le vrai risque d'une politique de réessai n'est pas qu'elle échoue :
      // c'est qu'elle fasse attendre sans fin devant un bouton qui tourne.
      var total = Duration.zero;
      for (var i = 0; i < kTrialLookupAttempts; i++) {
        total += trialLookupDelay(i);
      }
      expect(total.inMilliseconds, lessThan(6000));
    });
  });
}
