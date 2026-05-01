// Remplacé par lib/core/services/supabase_sync_service.dart
// Conservé pour compatibilité d'import
export '../../../../core/services/supabase_sync_service.dart';

// Alias de compatibilité
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../../core/config/supabase_client.dart';

class ProductSupabaseDataSource {
  final _db = SupabaseClientService.client;
}
