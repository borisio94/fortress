import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

class SupabaseService {
  static SupabaseClient get client => Supabase.instance.client;
  static GoTrueClient  get auth   => Supabase.instance.client.auth;

  static Future<void> init() async {
    await Supabase.initialize(
      url:     SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
  }

  static User?   get currentUser   => auth.currentUser;
  static String? get currentUserId => auth.currentUser?.id;
  static bool    get isAuthenticated => auth.currentUser != null;
}
