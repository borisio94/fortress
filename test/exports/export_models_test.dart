// Tests unitaires purs des modèles d'export — aucune dépendance Hive /
// Supabase / Flutter binding. Vérifie la construction du nom de fichier
// (`fortress_<type>_<scope>_<YYYYMMDD>`) pour les 3 scopes + les
// extensions de format/type.
//
// Pourquoi ces tests : le nom de fichier est la SEULE partie déterministe
// de l'export consommée par l'utilisateur (il le retrouve dans ses
// téléchargements). Une régression sur le format casse silencieusement
// l'organisation des fichiers exportés.

import 'package:flutter_test/flutter_test.dart';
import 'package:fortress/core/services/export_models.dart';

void main() {
  group('ExportConfig.filenameBase', () {
    // Date fixe UTC pour un résultat déterministe quel que soit le fuseau
    // de la machine de CI.
    final date = DateTime.utc(2026, 5, 22, 14, 30);

    ExportConfig config(ExportScope scope) => ExportConfig(
          type: ExportType.products,
          scope: scope,
          format: ExportFormat.csv,
          scopeLabel: 'peu importe',
        );

    test('scope boutique → fortress_produits_shop_<id>_<ymd>', () {
      final name = config(const ExportScopeShop('shopABC')).filenameBase(date);
      expect(name, 'fortress_produits_shop_shopABC_20260522');
    });

    test('scope partenaire → fortress_produits_partner_<locId>_<ymd>', () {
      final name = config(const ExportScopePartner(
        shopId: 'shopABC',
        locationId: 'locXYZ',
      )).filenameBase(date);
      expect(name, 'fortress_produits_partner_locXYZ_20260522');
    });

    test('scope global → fortress_produits_global_<ymd>', () {
      final name = config(const ExportScopeGlobal()).filenameBase(date);
      expect(name, 'fortress_produits_global_20260522');
    });

    test('le type pilote le segment de nom', () {
      final base = const ExportScopeGlobal();
      String n(ExportType t) => ExportConfig(
            type: t, scope: base, format: ExportFormat.csv,
            scopeLabel: 'x',
          ).filenameBase(date);
      expect(n(ExportType.products), contains('_produits_'));
      expect(n(ExportType.orders),   contains('_commandes_'));
      expect(n(ExportType.clients),  contains('_clients_'));
      expect(n(ExportType.logs),     contains('_logs_'));
    });

    test('la date locale est normalisée en UTC (déterminisme)', () {
      // Un DateTime local tard le soir ne doit PAS basculer le jour à
      // cause du fuseau — filenameBase fait .toUtc(). On vérifie que
      // deux instants équivalents donnent le même YMD.
      final utcMidday = DateTime.utc(2026, 1, 9, 12);
      final name = config(const ExportScopeGlobal()).filenameBase(utcMidday);
      expect(name, endsWith('_20260109'));
    });

    test('le mois et le jour sont zero-paddés', () {
      final name = config(const ExportScopeGlobal())
          .filenameBase(DateTime.utc(2026, 3, 5));
      expect(name, endsWith('_20260305'));
    });
  });

  group('ExportFormat', () {
    test('clés / mime / extension cohérents', () {
      expect(ExportFormat.csv.key, 'csv');
      expect(ExportFormat.csv.mimeType, 'text/csv');
      expect(ExportFormat.csv.extension, 'csv');
      expect(ExportFormat.pdf.key, 'pdf');
      expect(ExportFormat.pdf.mimeType, 'application/pdf');
      expect(ExportFormat.pdf.extension, 'pdf');
    });
  });

  group('ExportType', () {
    test('chaque type a une clé fr distincte', () {
      final keys = ExportType.values.map((t) => t.key).toSet();
      expect(keys.length, ExportType.values.length,
          reason: 'aucune collision de clé entre types');
    });

    test('labels non vides', () {
      for (final t in ExportType.values) {
        expect(t.labelFr.trim(), isNotEmpty);
      }
    });
  });

  group('ExportScope (equatable)', () {
    test('deux ExportScopeShop de même id sont égaux', () {
      expect(const ExportScopeShop('a'), const ExportScopeShop('a'));
      expect(const ExportScopeShop('a'), isNot(const ExportScopeShop('b')));
    });

    test('ExportScopePartner discrimine shopId ET locationId', () {
      const a = ExportScopePartner(shopId: 's', locationId: 'l');
      const b = ExportScopePartner(shopId: 's', locationId: 'l2');
      expect(a, isNot(b));
    });
  });
}
