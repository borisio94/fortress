import '../../../core/storage/hive_boxes.dart';

/// Stockage local des paramètres scopés par boutique.
/// Clé Hive : `shop_<shopId>_<setting>`
class ShopSettingsStore {
  final String shopId;
  const ShopSettingsStore(this.shopId);

  String _k(String key) => 'shop_${shopId}_$key';

  T? read<T>(String key, {T? fallback}) {
    final v = HiveBoxes.settingsBox.get(_k(key));
    if (v is T) return v;
    return fallback;
  }

  Future<void> write(String key, Object? value) async {
    if (value == null) {
      await HiveBoxes.settingsBox.delete(_k(key));
    } else {
      await HiveBoxes.settingsBox.put(_k(key), value);
    }
  }
}
