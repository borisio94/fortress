import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/promo_campaign_repository.dart';
import '../../domain/entities/promo_campaign.dart';

final promoCampaignRepositoryProvider =
    Provider<PromoCampaignRepository>((_) => PromoCampaignRepository());

class PromoCampaignsNotifier
    extends FamilyAsyncNotifier<List<PromoCampaign>, String> {
  PromoCampaignRepository get _repo =>
      ref.read(promoCampaignRepositoryProvider);

  @override
  Future<List<PromoCampaign>> build(String shopId) async {
    final cached = _repo.listFromCache(shopId);
    if (cached.isNotEmpty) {
      Future<void>.microtask(() async {
        try {
          final fresh = await _repo.refreshFromRemote(shopId);
          if (fresh.isEmpty) return;
          if (!_listEquals(fresh, cached)) {
            state = AsyncValue.data(fresh);
          }
        } catch (e) {
          debugPrint('[Promo] background refresh failed: $e');
        }
      });
      return cached;
    }
    try {
      return await _repo.refreshFromRemote(shopId);
    } catch (e) {
      debugPrint('[Promo] initial fetch failed: $e');
      return const [];
    }
  }

  Future<PromoCampaign> createCampaign({
    required PromoCampaignType        type,
    required String                   name,
    required List<PromoProductSnapshot> products,
    int?                              discountPercent,
    DateTime?                         validUntil,
    String?                           description,
  }) async {
    final c = await _repo.create(
      shopId:          arg,
      type:            type,
      name:            name,
      products:        products,
      discountPercent: discountPercent,
      validUntil:      validUntil,
      description:     description,
    );
    state = AsyncValue.data(_repo.listFromCache(arg));
    return c;
  }

  Future<PromoCampaign> updateCampaign(PromoCampaign c) async {
    final updated = await _repo.update(c);
    state = AsyncValue.data(_repo.listFromCache(arg));
    return updated;
  }

  Future<void> deleteCampaign(String campaignId) async {
    await _repo.delete(campaignId);
    state = AsyncValue.data(_repo.listFromCache(arg));
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      state = AsyncValue.data(await _repo.refreshFromRemote(arg));
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  bool _listEquals(List<PromoCampaign> a, List<PromoCampaign> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

final promoCampaignsProvider = AsyncNotifierProvider.family<
    PromoCampaignsNotifier, List<PromoCampaign>, String>(
  PromoCampaignsNotifier.new,
);
