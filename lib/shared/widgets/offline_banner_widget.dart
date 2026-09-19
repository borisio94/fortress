import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import '../../core/config/supabase_config.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/database/app_database.dart';
import '../../core/permisions/subscription_provider.dart';
import '../../core/storage/hive_boxes.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';
import 'package:go_router/go_router.dart';

// ── Provider connectivité — détection via connectivity_plus uniquement ──────
//
// On NE fait PAS de ping Supabase ici : au boot, l'utilisateur n'est pas
// encore authentifié, donc une requête sur `shops` échoue par RLS/timeout
// et l'état initial passe à tort à `offline` → la bannière reste visible
// même en ligne, car `onConnectivityChanged` ne se déclenche que sur
// changement d'interface (jamais si la connexion est stable depuis le début).
//
// `connectivity_plus` détecte l'interface (wifi/mobile/ethernet). C'est la
// source de vérité pour l'affichage de la bannière hors-ligne. La présence
// d'une interface ≠ accès internet réel garanti, mais c'est suffisant pour
// éviter les faux positifs ; les opérations qui ont vraiment besoin de
// joindre Supabase utilisent `AppDatabase.isOnline()` séparément.

/// Sonde de JOIGNABILITÉ RÉELLE du backend — bien plus fiable que le type
/// d'interface de connectivity_plus, AMBIGU sur web (renvoie souvent `other`
/// même hors ligne → l'app croyait rester en ligne alors que le wifi était
/// coupé). On tente un petit GET sur le health-check Supabase (CORS autorisé,
/// ~100 octets) : toute réponse HTTP = serveur joignable ; erreur réseau /
/// timeout / DNS = hors ligne. Même principe que navigator.onLine (utilisé par
/// WhatsApp Web) mais cross-plateforme (web + mobile) et calé sur le VRAI
/// backend de l'app.
Future<bool> _isReachable() async {
  try {
    final uri = Uri.parse('${SupabaseConfig.url}/auth/v1/health');
    final res = await http
        .get(uri, headers: {'apikey': SupabaseConfig.anonKey})
        .timeout(const Duration(seconds: 5));
    return res.statusCode > 0; // toute réponse = serveur joignable = en ligne
  } catch (_) {
    return false; // erreur réseau / timeout / DNS → hors ligne
  }
}

/// Flag levé par [SessionRefresher] quand 3 tentatives consécutives de
/// refresh token ont échoué. Inverse uniquement par un refresh réussi
/// (au retour du réseau, [SessionRefresher.refresh] le remet à false)
/// — sinon la bannière reste ouverte. Indépendant du flag connectivité
/// car un device peut "avoir une interface" (wifi captive, 3G dégradée)
/// sans pouvoir joindre Supabase.
final tokenRefreshFailedProvider = StateProvider<bool>((_) => false);

/// Provider booléen : true = aucune interface réseau active.
/// Initialisé immédiatement par une vérification synchrone, puis mis à jour
/// à chaque changement d'interface.
final isOfflineProvider = StreamProvider<bool>((ref) async* {
  // Sonde initiale, puis re-sonde à CHAQUE changement d'interface (réaction
  // rapide) ET toutes les 12 s (filet de sécurité : l'évènement
  // connectivity_plus ne fire pas toujours de façon fiable sur web, d'où le
  // bug « wifi coupé mais pas de puce hors-ligne »).
  var offline = !(await _isReachable());
  yield offline;

  final trigger = StreamController<void>();
  final subConn =
      Connectivity().onConnectivityChanged.listen((_) => trigger.add(null));
  final subTick = Stream<void>.periodic(const Duration(seconds: 12))
      .listen((_) => trigger.add(null));
  ref.onDispose(() {
    subConn.cancel();
    subTick.cancel();
    trigger.close();
  });

  await for (final _ in trigger.stream) {
    final now = !(await _isReachable());
    if (now != offline) {
      offline = now;
      yield now;
    }
  }
});

// ── Provider nombre d'ops en attente ─────────────────────────────────────────
final pendingOpsProvider = StreamProvider<int>((ref) async* {
  yield AppDatabase.pendingOpsCount;
  await for (final _ in Stream.periodic(const Duration(seconds: 2))) {
    yield AppDatabase.pendingOpsCount;
  }
});

// ── Widget principal ──────────────────────────────────────────────────────────
/// Bannière hors-ligne — visible UNIQUEMENT si l'appareil n'a pas de réseau.
/// En mode online : toujours invisible, même si des ops sont en attente
/// (elles sont envoyées automatiquement au retour du réseau).
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(isOfflineProvider);

    final isOffline = offline.when(
      data: (v) => v,
      loading: () => false,  // Pas de bannière pendant le chargement
      error: (_, __) => false,
    );

    // Visible si interface absente OU refresh token a échoué après 3
    // tentatives. Le 2e cas couvre les réseaux dégradés où l'interface
    // est présente mais Supabase est injoignable (captive portal, 3G
    // qui drop, DNS down).
    final tokenFailed = ref.watch(tokenRefreshFailedProvider);
    if (!isOffline && !tokenFailed) return const SizedBox.shrink();

    final pending = ref.watch(pendingOpsProvider);
    final pendingOps = pending.when(
      data: (n) => n,
      loading: () => 0,
      error: (_, __) => 0,
    );

    return _OfflineTap(pendingOps: pendingOps);
  }
}

// ── Puce compacte (barre du haut) ──────────────────────────────────────────
/// Petit indicatif hors-ligne destiné à la barre supérieure — remplace le
/// bandeau pleine largeur. Invisible en ligne ; visible dès que l'interface
/// réseau tombe (ou après 3 échecs de refresh token). Cliquable → même
/// feuille de détails que le bandeau.
class OfflineChip extends ConsumerWidget {
  const OfflineChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(isOfflineProvider).maybeWhen(
        data: (v) => v, orElse: () => false);
    final tokenFailed = ref.watch(tokenRefreshFailedProvider);
    if (!isOffline && !tokenFailed) return const SizedBox.shrink();

    final pendingOps = ref.watch(pendingOpsProvider).maybeWhen(
        data: (n) => n, orElse: () => 0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Center(
        widthFactor: 1,
        child: GestureDetector(
          onTap: () => showModalBottomSheet(
            context: context,
            backgroundColor: Theme.of(context).colorScheme.surface,
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
            builder: (_) => _OfflineSheet(pendingOps: pendingOps),
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFFEE2E2), // rouge pâle
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: const Color(0xFFDC2626).withValues(alpha:0.35)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.wifi_off_rounded,
                  size: 13, color: Color(0xFFDC2626)),
              const SizedBox(width: 4),
              Text(
                pendingOps > 0
                    ? '${context.l10n.offlineShort} · $pendingOps'
                    : context.l10n.offlineShort,
                style: AppTextStyles.caption.copyWith(
                    color: const Color(0xFFDC2626),
                    fontWeight: FontWeight.w700),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Bannière cliquable ─────────────────────────────────────────────────────────
class _OfflineTap extends StatelessWidget {
  final int pendingOps;
  const _OfflineTap({required this.pendingOps});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;

    return GestureDetector(
      onTap: () => _showSheet(context),
      child: Container(
        width: double.infinity,
        color: const Color(0xFFDC2626),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.wifi_off_rounded, color: Colors.white, size: 15),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pendingOps > 0
                    ? l.offlinePendingOps(pendingOps)
                    : l.offlineMode,
                style: AppTextStyles.bodySm.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white70, size: 16),
          ],
        ),
      ),
    );
  }

  void _showSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _OfflineSheet(pendingOps: pendingOps),
    );
  }
}

// ── Bottom sheet ───────────────────────────────────────────────────────────────
class _OfflineSheet extends StatelessWidget {
  final int pendingOps;
  const _OfflineSheet({required this.pendingOps});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Poignée
          Container(
            width: 36, height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).semantic.borderSubtle,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Icône
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFDC2626).withValues(alpha:0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.wifi_off_rounded,
                color: Color(0xFFDC2626), size: 26),
          ),
          const SizedBox(height: 14),

          // Titre
          Text(
            l.offlineMode.split('—').first.trim(),
            style: AppTextStyles.subtitleBold.copyWith(
                color: Theme.of(context).colorScheme.onSurface),
          ),
          const SizedBox(height: 8),

          // Description
          Text(
            l.offlineDescription,
            textAlign: TextAlign.center,
            style: AppTextStyles.bodySecondary.copyWith(
                color: AppColors.textSecondary),
          ),

          // Info ops en attente
          if (pendingOps > 0) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFF59E0B)),
              ),
              child: Row(children: [
                const Icon(Icons.schedule_rounded,
                    size: 16, color: Color(0xFFF59E0B)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.offlinePendingOps(pendingOps),
                    style: AppTextStyles.bodySm.copyWith(
                        color: const Color(0xFF92400E)),
                  ),
                ),
              ]),
            ),
          ],

          const SizedBox(height: 20),

          // Bouton fermer
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                side: BorderSide(color: Theme.of(context).semantic.borderSubtle),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(l.close,
                  style: AppTextStyles.body.copyWith(
                      color: AppColors.textSecondary)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Blocage offline pour plan Normal ────────────────────────────────────────
// Affiche un écran de blocage si :
// - Le plan est Normal (offline_enabled = false)
// - L'appareil est hors ligne
// - **ET c'est la première utilisation sur ce device** (Hive vide). Une
//   fois que l'app a été utilisée au moins une fois en ligne (= au moins
//   une boutique synchronisée localement), le user peut continuer à
//   l'utiliser hors ligne en lecture du cache, même sur plan Normal —
//   l'écran de blocage est seulement là pour empêcher un user FRESH
//   install de se faire piéger sans contenu.
class OfflineBlockGuard extends ConsumerWidget {
  final Widget child;
  const OfflineBlockGuard({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(isOfflineProvider).valueOrNull ?? false;
    final planAsync = ref.watch(subscriptionProvider);
    final plan = planAsync.valueOrNull;
    // Premier login sur ce device = aucune boutique en cache local. Si
    // au moins 1 boutique a été synchronisée auparavant, on considère
    // que l'utilisateur a un état utilisable hors-ligne et on lève le
    // blocage (lecture seule cache). Cf. spec round 9.
    final isFirstTimeOnDevice = HiveBoxes.shopsBox.isEmpty;

    // Bloquer si hors ligne ET plan ne permet pas l'offline ET premier
    // login sur ce device.
    if (offline
        && plan != null
        && !plan.offlineEnabled
        && !plan.isSuperAdmin
        && isFirstTimeOnDevice) {
      return Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Center(
            child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      shape: BoxShape.circle),
                  child: const Icon(Icons.wifi_off_rounded,
                      size: 36, color: Color(0xFFEF4444)),
                ),
                const SizedBox(height: 24),
                Text('Connexion requise',
                    style: AppTextStyles.title.copyWith(
                        fontWeight: FontWeight.w800,
                        color: Theme.of(context).colorScheme.onSurface)),
                const SizedBox(height: 8),
                Text(
                    "Votre plan Normal nécessite une connexion internet. "
                        "Activez le plan Pro pour utiliser l'application hors ligne.",
                style: AppTextStyles.bodySecondary.copyWith(
                    color: AppColors.textSecondary),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            // Bouton upgrade
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => context.push('/subscription'),
                icon: const Icon(Icons.stars_rounded, size: 16),
                label: Text('Passer au plan Pro',
                    style: AppTextStyles.body.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white)),
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
              ),
            ),
            const SizedBox(height: 10),
            // Bouton réessayer
            TextButton(
              onPressed: () => ref.invalidate(isOfflineProvider),
              child: Text('Réessayer la connexion',
                  style: AppTextStyles.bodySecondary.copyWith(
                      color: AppColors.textSecondary)),
            ),
            ],
          ),
        ),
      ),
    ),
    );
  }

    return child;
  }
}