import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/delivery_template_repository.dart';
import '../../domain/entities/delivery_template.dart';

/// Repository singleton (stateless, accessible aussi depuis le builder).
final deliveryTemplateRepositoryProvider =
    Provider<DeliveryTemplateRepository>((_) => DeliveryTemplateRepository());

/// Liste réactive des templates d'un shop. Comportement offline-first :
/// retourne le cache Hive immédiatement, puis lance un refresh Supabase
/// en arrière-plan qui met à jour [state] si différence.
class DeliveryTemplatesNotifier
    extends FamilyAsyncNotifier<List<DeliveryTemplate>, String> {

  DeliveryTemplateRepository get _repo =>
      ref.read(deliveryTemplateRepositoryProvider);

  @override
  Future<List<DeliveryTemplate>> build(String shopId) async {
    final cached = _repo.listFromCache(shopId);
    if (cached.isNotEmpty) {
      // Background refresh — n'écrase pas le cache si la requête échoue
      // ou retourne vide (cf. pattern employees_provider).
      Future<void>.microtask(() async {
        try {
          final fresh = await _repo.refreshFromRemote(shopId);
          if (fresh.isEmpty) return;
          if (!_listEquals(fresh, cached)) {
            state = AsyncValue.data(fresh);
          }
        } catch (e) {
          debugPrint('[DeliveryTpl] background refresh failed: $e');
        }
      });
      return cached;
    }
    // Cache vide → fetch synchrone (premier chargement après login).
    try {
      return await _repo.refreshFromRemote(shopId);
    } catch (e) {
      debugPrint('[DeliveryTpl] initial fetch failed: $e');
      return const [];
    }
  }

  Future<DeliveryTemplate> createTemplate({
    required String name,
    required String body,
    bool isDefault = false,
  }) async {
    final shopId = arg;
    final tpl = await _repo.create(
        shopId: shopId, name: name, body: body, isDefault: isDefault);
    // Refresh complet : si isDefault=true, d'autres rows ont changé aussi.
    state = AsyncValue.data(_repo.listFromCache(shopId));
    return tpl;
  }

  Future<DeliveryTemplate> updateTemplate(DeliveryTemplate tpl) async {
    final updated = await _repo.update(tpl);
    state = AsyncValue.data(_repo.listFromCache(arg));
    return updated;
  }

  Future<void> deleteTemplate(String templateId) async {
    await _repo.delete(templateId);
    state = AsyncValue.data(_repo.listFromCache(arg));
  }

  /// Force un refresh complet depuis Supabase.
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final fresh = await _repo.refreshFromRemote(arg);
      state = AsyncValue.data(fresh);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  bool _listEquals(List<DeliveryTemplate> a, List<DeliveryTemplate> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final deliveryTemplatesProvider = AsyncNotifierProvider.family<
    DeliveryTemplatesNotifier, List<DeliveryTemplate>, String>(
  DeliveryTemplatesNotifier.new,
);
