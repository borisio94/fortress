// ⚠️ NE PAS COMMITER — ajouté dans .gitignore
//
// SETUP initial (à faire une seule fois par projet Supabase) :
//   1. Exécuter supabase/bootstrap.sql dans SQL Editor
//   2. Lancer l'app → les migrations supabase/migrations/*.sql se poussent
//   3. Ajouter ton email dans super_admin_whitelist pour être SA :
//        INSERT INTO super_admin_whitelist (email, note)
//        VALUES ('ton.email@exemple.com', 'Fondateur')
//        ON CONFLICT (email) DO NOTHING;
//   4. T'inscrire dans l'app avec cet email → élévation SA automatique
class SupabaseConfig {
  static const String url     = 'https://hyxvussnlnvbkalqzovb.supabase.co';
  static const String anonKey = 'sb_publishable_R7Jg-Tx4WRMkVI5TMC4jpQ_p8NHq4bd';

  /// URL vers laquelle Supabase redirige après avoir cliqué sur un magic-link
  /// d'invitation. Doit être configurée dans :
  ///   - Supabase → Auth → URL Configuration → Redirect URLs
  ///   - Platform deep link :
  ///       • Android : <intent-filter> avec android:host/scheme dans AndroidManifest
  ///       • iOS : Associated Domains + apple-app-site-association
  ///       • Web : route GoRouter /accept-invite (déjà configurée)
  ///
  /// Ajuster selon le domaine / scheme utilisé en prod.
  static const String acceptInviteBaseUrl =
      'https://stately-sunshine-3593ef.netlify.app/accept-invite';
}
