import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';

/// Base d'un écran restaurant qui se rafraîchit quand ses tables changent.
///
/// La badgeuse tourne sur une tablette, la paie s'ouvre sur le téléphone du
/// gérant : sans cette écoute, l'excuse saisie à l'entrée du personnel
/// n'apparaîtrait sur l'écran du gérant qu'après un retour arrière et un
/// rechargement — c'est-à-dire jamais.
///
/// Extraite de `restaurant_staff_page` (hotfix_165) : les onglets Notation et
/// Primes vivent dans leurs propres fichiers et ont exactement le même besoin.
abstract class RestoTableListenerState<T extends StatefulWidget>
    extends State<T> {
  /// Tables Supabase à écouter.
  List<String> get tables;
  String get shopId;

  late final OnDataChanged _listener;

  @override
  void initState() {
    super.initState();
    _listener = (t, sid) {
      if (!mounted) return;
      if (!tables.contains(t)) return;
      if (sid != shopId && sid != '_all') return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }
}
