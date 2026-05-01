// Fichier maintenu pour compatibilité — utiliser supabase_service.dart
export '../services/supabase_service.dart' show SupabaseService;

// Alias de compatibilité pour les fichiers qui utilisent SupabaseClientService
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_config.dart';

class SupabaseClientService {
  static get client  => Supabase.instance.client;
  static get auth    => Supabase.instance.client.auth;
  static String? get currentUserId => Supabase.instance.client.auth.currentUser?.id;
  static bool get isAuthenticated  => Supabase.instance.client.auth.currentUser != null;
}
