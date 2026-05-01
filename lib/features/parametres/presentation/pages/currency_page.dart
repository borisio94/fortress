import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/theme/app_colors.dart';
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
    _selected = _store.read<String>('currency_code', fallback: 'XAF') ?? 'XAF';
  }

  Future<void> _select(String code) async {
    HapticFeedback.selectionClick();
    if (code == _selected) return;
    setState(() => _selected = code);
    await _store.write('currency_code', code);
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
        itemCount: _currencies.length,
        itemBuilder: (context, index) {
          final c = _currencies[index];
          final selected = c.code == _selected;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected
                    ? AppColors.primary
                    : const Color(0xFFE5E7EB),
                width: selected ? 1.5 : 1,
              ),
            ),
            child: ListTile(
              leading: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primary.withOpacity(0.1)
                      : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(c.symbol,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: selected
                              ? AppColors.primary
                              : const Color(0xFF6B7280))),
                ),
              ),
              title: Text(c.code,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: selected
                          ? AppColors.primary
                          : const Color(0xFF111827))),
              subtitle: Text(c.name(isFr),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
              trailing: selected
                  ? Icon(Icons.check_circle,
                      color: AppColors.primary, size: 22)
                  : const Icon(Icons.circle_outlined,
                      color: Color(0xFFD1D5DB), size: 22),
              onTap: () => _select(c.code),
            ),
          );
        },
      ),
    );
  }
}
