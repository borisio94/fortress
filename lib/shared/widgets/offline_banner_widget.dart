import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../core/i18n/app_localizations.dart';
import '../../core/database/app_database.dart';
import '../../core/permisions/subscription_provider.dart';
import '../../core/storage/hive_boxes.dart';
import '../../core/theme/app_colors.dart';
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

bool _hasNetworkInterface(List<ConnectivityResult> results) => results.any(
      (r) =>
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.mobile ||
          r == ConnectivityResult.ethernet,
    );

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
  // 1. Vérification synchrone immédiate au démarrage
  final initial = await Connectivity().checkConnectivity();
  yield !_hasNetworkInterface(initial);

  // 2. Écoute des changements d'interface
  await for (final results in Connectivity().onConnectivityChanged) {
    yield !_hasNetworkInterface(results);
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
                style: const TextStyle(
                    color: Colors.white, fontSize: 12,
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
      backgroundColor: Colors.white,
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
              color: const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Icône
          Container(
            width: 56, height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFDC2626).withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.wifi_off_rounded,
                color: Color(0xFFDC2626), size: 26),
          ),
          const SizedBox(height: 14),

          // Titre
          Text(
            l.offlineMode.split('—').first.trim(),
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700,
                color: Color(0xFF0F172A)),
          ),
          const SizedBox(height: 8),

          // Description
          Text(
            l.offlineDescription,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13, color: Color(0xFF6B7280), height: 1.5),
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
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF92400E)),
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
                foregroundColor: const Color(0xFF6B7280),
                side: const BorderSide(color: Color(0xFFE5E7EB)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(l.close,
                  style: const TextStyle(fontSize: 13)),
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
        backgroundColor: const Color(0xFFF8F7FC),
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
                const Text('Connexion requise',
                    style: TextStyle(fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A))),
                const SizedBox(height: 8),
                const Text(
                    "Votre plan Normal nécessite une connexion internet. "
                        "Activez le plan Pro pour utiliser l'application hors ligne.",
                style: TextStyle(fontSize: 13,
                    color: Color(0xFF6B7280)),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            // Bouton upgrade
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => context.push('/subscription'),
                icon: const Icon(Icons.stars_rounded, size: 16),
                label: const Text('Passer au plan Pro',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
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
              child: const Text('Réessayer la connexion',
                  style: TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B7280))),
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