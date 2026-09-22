import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../data/shop_settings_store.dart';

class _Currency {
  final String code;
  final String nameFr;
  final String nameEn;
  final String symbol;
  const _Currency(this.code, this.nameFr, this.nameEn, this.symbol);

  String name(bool isFr) => isFr ? nameFr : nameEn;
}

const _currencies = <_Currency>[
  _Currency('XAF', 'Franc CFA BEAC',  'CFA Franc BEAC',  'FCFA'),
  _Currency('XOF', 'Franc CFA BCEAO', 'CFA Franc BCEAO', 'FCFA'),
  _Currency('EUR', 'Euro',             'Euro',            '€'),
  _Currency('USD', 'Dollar américain', 'US Dollar',       '\$'),
  _Currency('NGN', 'Naira nigérian',   'Nigerian Naira',  '₦'),
  _Currency('GHS', 'Cedi ghanéen',     'Ghanaian Cedi',   '₵'),
  _Currency('MAD', 'Dirham marocain',  'Moroccan Dirham', 'DH'),
  _Currency('GBP', 'Livre sterling',   'Pound Sterling',  '£'),
  // Le franc congolais manquait à cette liste alors que la RDC figure au
  // sélecteur de pays : un commerçant de Kinshasa à qui l'inscription avait
  // imposé XAF ne pouvait même pas se corriger.
  _Currency('CDF', 'Franc congolais',  'Congolese Franc', 'FC'),
];

class CurrencyPage extends ConsumerStatefulWidget {
  final String? shopId;
  const CurrencyPage({super.key, this.shopId});

  @override
  ConsumerState<CurrencyPage> createState() => _CurrencyPageState();
}

class _CurrencyPageState extends ConsumerState<CurrencyPage> {
  late final ShopSettingsStore _store =
      ShopSettingsStore(widget.shopId ?? '_app');
  String _selected = 'XAF';

  @override
  void initState() {
    super.initState();
    // LA BOUTIQUE D'ABORD, le cache local ensuite.
    //
    // Deux vérités coexistaient pour la devise d'une même boutique :
    // `shops.currency`, posée à la création et affichée par les écrans de
    // boutique, et cette clé Hive, seule modifiable — mais LOCALE, jamais
    // synchronisée. Un commerçant qui se corrigeait ici voyait sa correction
    // rester sur son appareil, pendant que le téléphone de son serveur
    // continuait d'afficher l'ancienne.
    final shopId = widget.shopId;
    final fromShop = shopId == null || shopId.isEmpty
        ? null
        : LocalStorageService.getShop(shopId)?.currency;
    _selected = _store.read<String>('currency_code',
            fallback: (fromShop ?? 'XAF')) ??
        'XAF';
  }

  Future<void> _select(String code) async {
    HapticFeedback.selectionClick();
    if (code == _selected) return;
    setState(() => _selected = code);

    // 1. Le cache local, pour un rendu immédiat et hors ligne.
    await _store.write('currency_code', code);
    // Met à jour la devise globale + notifie les widgets sensibles
    // (CurrencyFormatter.notifier) pour rebuild immédiat.
    CurrencyFormatter.setCurrent(code, shopId: widget.shopId);

    // 2. ET LA BOUTIQUE, pour que la correction VOYAGE.
    //
    // `ShopSettingsStore` est du Hive local, jamais synchronisé : sans cette
    // seconde écriture, la correction restait sur l'appareil qui l'avait
    // faite. Les écrans de boutique (`edit_shop_page`, `create_shop_page`)
    // affichent `shops.currency`, qui serait resté faux, et un second
    // appareil aurait continué sur l'ancienne devise.
    //
    // En arrière-plan : `updateShop` passe par le réseau, et un réglage ne
    // doit pas attendre. L'échec est rattrapé au prochain passage — la valeur
    // locale, elle, est déjà juste.
    final shopId = widget.shopId;
    if (shopId != null && shopId.isNotEmpty) {
      try {
        await AppDatabase.updateShop(shopId: shopId, currency: code);
      } catch (e) {
        debugPrint('[Currency] push boutique err: $e');
      }
    }

    if (mounted) AppSnack.success(context, context.l10n.commonSaved);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final isFr = Localizations.localeOf(context).languageCode == 'fr';

    return AppScaffold(
      shopId: widget.shopId ?? '',
      title: l.paramCurrency,
      isRootPage: false,
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        // +1 : l'avertissement occupe la première ligne de la liste.
        itemCount: _currencies.length + 1,
        itemBuilder: (context, index) {
          // CE QUI CHANGE, ET CE QUI NE CHANGE PAS. Remplacer une devise
          // fausse par une attente fausse ne vaudrait pas mieux : les montants
          // déjà saisis ne sont PAS reconvertis, seul leur symbole change.
          // Pour qui corrige une déduction erronée — le cas de ce réglage —
          // c'est exactement le résultat voulu.
          if (index == 0) {
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                        'Changer de monnaie ne recalcule aucun montant : '
                        'seul le symbole affiché change. Utile pour corriger '
                        'une monnaie devinée à l\'inscription.',
                        style: AppTextStyles.captionHint),
                  ),
                ],
              ),
            );
          }
          final c = _currencies[index - 1];
          final selected = c.code == _selected;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? AppColors.primary
                    : Theme.of(context).semantic.borderSubtle,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primary.withValues(alpha:0.1)
                      : AppColors.inputFill,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(c.symbol,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: selected
                              ? AppColors.primary
                              : AppColors.textSecondary)),
                ),
              ),
              title: Text(c.code,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? AppColors.primary
                          : Theme.of(context).colorScheme.onSurface)),
              subtitle: Text(c.name(isFr),
                  style: TextStyle(
                      fontSize: 12, color: AppColors.textSecondary)),
              trailing: selected
                  ? Icon(Icons.check_circle,
                      color: AppColors.primary, size: 22)
                  : Icon(Icons.circle_outlined,
                      color: AppColors.textHint, size: 22),
              onTap: () => _select(c.code),
            ),
          );
        },
      ),
    );
  }
}
