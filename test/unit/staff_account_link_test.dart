// Deux homonymes ne pouvaient pas avoir chacun leur fiche.
//
// Le formulaire du personnel retire de la liste des comptes ceux qui ont déjà
// leur fiche — sans ce filtre, on créerait deux fiches pour la même personne,
// et c'est un mois de salaire coupé en deux.
//
// Le rapprochement se faisait sur le NOM, faute de lien stocké, et le code
// l'avouait : « c'est imparfait — deux homonymes seraient confondus ».
//
// AVEC DEUX « AWA NDIAYE » DANS L'ÉQUIPE, la première fiche créée faisait
// disparaître la seconde de la liste des comptes. Son compte devenait
// inéligible, et le gérant n'avait aucun moyen de lui créer sa fiche — ni de
// comprendre pourquoi. Le dédoublonnage des fiches, lui, n'a jamais reposé sur
// le nom : `staff_service` compare le code de pointage et le téléphone, et
// écrit pourquoi. L'écran du personnel n'avait pas suivi cette règle, faute de
// pouvoir le faire.
//
// `StaffMember.userId` porte le lien depuis le hotfix_182. Le nom reste un
// repli pour les fiches antérieures, qui n'en auront jamais : on ne devine pas
// rétroactivement à quel compte chacune correspondait.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/features/restaurant/domain/staff_account_link.dart';

/// Une fiche LIÉE à un compte — créée depuis la liste des comptes.
StaffLink _linked(String userId, String name) =>
    (userId: userId, fullName: name);

/// Une fiche SANS lien — saisie à la main, ou antérieure au hotfix_182.
StaffLink _loose(String name) => (userId: null, fullName: name);

void main() {
  group('Ce compte a-t-il déjà sa fiche', () {
    test('oui, si une fiche porte son identifiant', () {
      expect(
          accountHasStaffRecord(
              userId: 'u_awa',
              fullName: 'Awa Ndiaye',
              staff: [_linked('u_awa', 'Awa Ndiaye')]),
          isTrue);
    });

    test('non, si aucune fiche ne le concerne', () {
      expect(
          accountHasStaffRecord(
              userId: 'u_awa',
              fullName: 'Awa Ndiaye',
              staff: [_linked('u_moussa', 'Moussa Bâ')]),
          isFalse);
    });

    test('DEUX HOMONYMES NE SE CONFONDENT PLUS', () {
      // LE test de ce lot. La fiche de la PREMIÈRE Awa est liée à son compte ;
      // elle ne doit plus rien dire du compte de la seconde.
      expect(
          accountHasStaffRecord(
              userId: 'u_awa_2',
              fullName: 'Awa Ndiaye',
              staff: [_linked('u_awa_1', 'Awa Ndiaye')]),
          isFalse);
    });

    test('et le lien tranche même quand les noms diffèrent', () {
      // Une personne dont le compte a été renommé après la création de sa
      // fiche. Le nom ne colle plus, le lien si — et c'est lui qui compte.
      expect(
          accountHasStaffRecord(
              userId: 'u_awa',
              fullName: 'Awa Ngono',
              staff: [_linked('u_awa', 'Awa Ndiaye')]),
          isTrue);
    });
  });

  group('Le repli par le nom, pour les fiches sans lien', () {
    test('une fiche ANTÉRIEURE bloque encore son homonyme', () {
      // Comportement conservé à dessein : une fiche créée avant le hotfix_182
      // n'a pas de lien et n'en aura jamais. Sans ce repli, le gérant se
      // verrait proposer un compte déjà pourvu, et créerait le doublon que
      // tout ce filtre existe pour éviter.
      expect(
          accountHasStaffRecord(
              userId: 'u_awa',
              fullName: 'Awa Ndiaye',
              staff: [_loose('Awa Ndiaye')]),
          isTrue);
    });

    test('la casse et les espaces ne comptent pas', () {
      expect(
          accountHasStaffRecord(
              userId: 'u_awa',
              fullName: '  awa NDIAYE ',
              staff: [_loose('Awa Ndiaye')]),
          isTrue);
    });

    test('une fiche LIÉE À QUELQU\'UN D\'AUTRE ne bloque plus par le nom', () {
      // La distinction qui fait tout le lot : le repli ne s'applique qu'aux
      // fiches sans lien. Une fiche liée parle d'un compte précis, et d'aucun
      // autre.
      expect(
          accountHasStaffRecord(
              userId: 'u_awa_2',
              fullName: 'Awa Ndiaye',
              staff: [
                _linked('u_awa_1', 'Awa Ndiaye'),
                _linked('u_moussa', 'Moussa Bâ'),
              ]),
          isFalse);
    });

    test('mêlées, les deux règles cohabitent', () {
      final equipe = [
        _linked('u_awa_1', 'Awa Ndiaye'), // liée
        _loose('Moussa Bâ'), // ancienne, sans lien
      ];
      // L'homonyme d'une fiche LIÉE passe…
      expect(
          accountHasStaffRecord(
              userId: 'u_awa_2', fullName: 'Awa Ndiaye', staff: equipe),
          isFalse);
      // …l'homonyme d'une fiche SANS LIEN reste bloqué.
      expect(
          accountHasStaffRecord(
              userId: 'u_moussa', fullName: 'Moussa Bâ', staff: equipe),
          isTrue);
    });
  });
}
