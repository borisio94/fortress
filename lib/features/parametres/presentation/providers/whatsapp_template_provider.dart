import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/whatsapp_template_repository.dart';
import '../../domain/entities/whatsapp_template.dart';

/// Repository singleton (stateless, accessible aussi depuis les services
/// hors widget tree comme les call sites WhatsApp).
final whatsappTemplateRepositoryProvider =
    Provider<WhatsappTemplateRepository>(
        (_) => WhatsappTemplateRepository());

/// Liste réactive des templates d'un shop. Comportement offline-first :
/// retourne le cache Hive immédiatement, puis lance un refresh Supabase en
/// arrière-plan qui met à jour [state] si différence.
///
/// Au premier build, déclenche aussi un seed des templates par défaut si
/// le cache est vide (1 template par type avec defaultBody/defaultName).
class WhatsappTemplatesNotifier
    extends FamilyAsyncNotifier<List<WhatsappTemplate>, String> {

  WhatsappTemplateRepository get _repo =>
      ref.read(whatsappTemplateRepositoryProvider);

  @override
  Future<List<WhatsappTemplate>> build(String shopId) async {
    final cached = _repo.listFromCache(shopId);
    if (cached.isNotEmpty) {
      // Refresh background — n'écrase pas si la requête échoue / retourne vide.
      Future<void>.microtask(() async {
        try {
          final fresh = await _repo.refreshFromRemote(shopId);
          if (fresh.isEmpty) return;
          if (!_listEquals(fresh, cached)) {
            state = AsyncValue.data(fresh);
          }
          // Seed si manquant (idempotent).
          await _repo.seedDefaultsIfMissing(shopId);
          final afterSeed = _repo.listFromCache(shopId);
          if (afterSeed.length != fresh.length) {
            state = AsyncValue.data(afterSeed);
          }
        } catch (e) {
          debugPrint('[WaTpl] background refresh failed: $e');
        }
      });
      return cached;
    }
    // Cache vide → fetch synchrone (premier chargement après login).
    try {
      final fresh = await _repo.refreshFromRemote(shopId);
      if (fresh.isEmpty) {
        // Premier accès jamais — seed les défauts.
        await _repo.seedDefaultsIfMissing(shopId);
        return _repo.listFromCache(shopId);
      }
      return fresh;
    } catch (e) {
      debugPrint('[WaTpl] initial fetch failed: $e');
      return const [];
    }
  }

  Future<WhatsappTemplate> createTemplate({
    required WhatsappTemplateType type,
    required String name,
    required String body,
    bool isDefault = false,
  }) async {
    final shopId = arg;
    final tpl = await _repo.create(
        shopId: shopId, type: type, name: name, body: body,
        isDefault: isDefault);
    state = AsyncValue.data(_repo.listFromCache(shopId));
    return tpl;
  }

  Future<WhatsappTemplate> updateTemplate(WhatsappTemplate tpl) async {
    final updated = await _repo.update(tpl);
    state = AsyncValue.data(_repo.listFromCache(arg));
    return updated;
  }

  Future<void> deleteTemplate(String templateId) async {
    await _repo.delete(templateId);
    state = AsyncValue.data(_repo.listFromCache(arg));
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final fresh = await _repo.refreshFromRemote(arg);
      state = AsyncValue.data(fresh);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  bool _listEquals(List<WhatsappTemplate> a, List<WhatsappTemplate> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final whatsappTemplatesProvider = AsyncNotifierProvider.family<
    WhatsappTemplatesNotifier, List<WhatsappTemplate>, String>(
  WhatsappTemplatesNotifier.new,
);
