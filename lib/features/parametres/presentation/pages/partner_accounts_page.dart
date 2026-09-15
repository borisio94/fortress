import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import 'partner_hub_detail_page.dart';

/// Résout le nom d'un partenaire (StockLocation) depuis Hive, fallback id.
String _partnerName(String id) {
  try {
    final raw = HiveBoxes.stockLocationsBox.get(id);
    if (raw == null) return 'Partenaire $id';
    return StockLocation.fromMap(Map<String, dynamic>.from(raw)).name;
  } catch (_) {
    return 'Partenaire $id';
  }
}

/// Liste des comptes partenaires avec leur solde courant.
/// Convention :
///   * solde > 0 → le partenaire DOIT cet argent à la boutique
///   * solde < 0 → la boutique DOIT cet argent au partenaire
///   * solde = 0 → comptes à jour (le partenaire n'apparaît pas)
class PartnerAccountsPage extends ConsumerStatefulWidget {
  final String shopId;
  const PartnerAccountsPage({super.key, required this.shopId});
  @override
  ConsumerState<PartnerAccountsPage> createState() =>
      _PartnerAccountsPageState();
}

class _PartnerAccountsPageState extends ConsumerState<PartnerAccountsPage> {
  late void Function(String, String) _listener;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (sid != widget.shopId) return;
      if (table == 'partner_ledger_entries' || table == 'stock_locations') {
        setState(() {});
      }
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  /// Règle le seuil d'ancienneté au-delà duquel une vente non reversée est
  /// signalée. Le réglage vit sur `shops` (partagé par tous les appareils),
  /// pas dans `ShopSettingsStore` qui resterait local à celui-ci.
  Future<void> _editAlertDays() async {
    final current =
        ref.read(currentShopProvider)?.partnerDebtAlertDays ?? 30;
    final res = await showFormSheet<int>(
      context: context,
      builder: (_) => _AlertDaysSheet(initial: current),
    );
    if (res == null || !mounted) return;
    try {
      await AppDatabase.updateShop(
          shopId: widget.shopId, partnerDebtAlertDays: res);
      ref.invalidate(currentShopProvider);
      if (mounted) {
        AppSnack.success(context, 'Alerte au-delà de $res jours.');
      }
    } catch (e) {
      // `updateShop` écrit DIRECTEMENT dans Supabase, sans passer par la
      // file hors-ligne : sans réseau, l'appel échoue. On le dit, plutôt
      // que de laisser croire à un réglage enregistré.
      if (mounted) {
        AppSnack.error(context,
            'Réglage impossible hors ligne — réessayez une fois connecté.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final balances = PartnerLedgerService.balancesForShop(widget.shopId);
    final ages     = PartnerLedgerService.debtAgeByPartner(widget.shopId);
    final alertDays =
        ref.watch(currentShopProvider)?.partnerDebtAlertDays ?? 30;
    // On liste TOUS les partenaires : ceux qui détiennent du stock
    // (StockLocation type=partner actifs) ET ceux qui ont un mouvement
    // financier (même si leur dépôt a été archivé). Ainsi on accède à la
    // fiche d'un partenaire pour son stock même sans dette en cours.
    final partnerIds = <String>{
      ...AppDatabase.getStockLocationsForOwner(userId)
          .where((l) => l.type == StockLocationType.partner && l.isActive)
          .map((l) => l.id),
      ...balances.keys,
    };
    // Tri : dettes les plus grosses en haut (signe absolu décroissant) pour
    // que l'opérateur voie d'abord ce qu'il y a à régler ; à solde égal,
    // tri alphabétique.
    final entries = partnerIds
        .map((id) => MapEntry(id, balances[id] ?? 0.0))
        .toList()
      ..sort((a, b) {
        final byBalance = b.value.abs().compareTo(a.value.abs());
        if (byBalance != 0) return byBalance;
        return _partnerName(a.key)
            .toLowerCase()
            .compareTo(_partnerName(b.key).toLowerCase());
      });

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Partenaires',
      actions: [
        IconButton(
          tooltip: 'Seuil d\'alerte ($alertDays jours)',
          icon: const Icon(Icons.tune_rounded),
          onPressed: _editAlertDays,
        ),
      ],
      body: entries.isEmpty
          ? _emptyState(context)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              itemCount: entries.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _PartnerCard(
                shopId:    widget.shopId,
                partnerId: entries[i].key,
                balance:   entries[i].value,
                days:      ages[entries[i].key],
                alertDays: alertDays,
              ),
            ),
    );
  }

  Widget _emptyState(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.local_shipping_outlined, size: 56,
                  color: AppColors.textHint),
              const SizedBox(height: 12),
              Text('Aucun compte ouvert',
                  style: AppTextStyles.label),
              const SizedBox(height: 4),
              Text(
                'Les comptes apparaissent automatiquement dès qu\'une '
                'commande génère une dette croisée avec un partenaire '
                '(vente encaissée par lui ou frais de livraison à payer).',
                textAlign: TextAlign.center,
                style: AppTextStyles.bodySm.copyWith(color: AppColors.textHint),
              ),
            ],
          ),
        ),
      );
}

class _PartnerCard extends StatelessWidget {
  final String shopId;
  final String partnerId;
  final double balance;
  /// Ancienneté de la plus vieille vente non reversée (cf.
  /// `PartnerLedgerService.debtAgeByPartner`). `null` = rien qui vieillisse.
  final int? days;
  final int alertDays;
  const _PartnerCard({
    required this.shopId, required this.partnerId, required this.balance,
    this.days, required this.alertDays,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final partnerName = _partnerName(partnerId);
    final partnerOwesBoutique = balance > 0;
    final boutiqueOwesPartner = balance < 0;
    final color = partnerOwesBoutique
        ? sem.success
        : (boutiqueOwesPartner ? sem.danger : sem.borderSubtle);
    final tag = partnerOwesBoutique
        ? 'Le partenaire vous doit'
        : (boutiqueOwesPartner
            ? 'Vous devez au partenaire'
            : 'À jour');
    final isLate = days != null && days! > alertDays;

    return InkWell(
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PartnerHubDetailPage(
            shopId: shopId, partnerLocationId: partnerId),
        ));
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sem.borderSubtle),
        ),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.local_shipping_outlined, size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(partnerName,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.label),
            const SizedBox(height: 2),
            Row(children: [
              Flexible(
                child: Text(tag,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.captionHint),
              ),
              // Ancienneté absente = rien qui vieillisse : tout est couvert,
              // ou le solde ne tient qu'à une avance consentie.
              if (days != null)
                Text(' · depuis $days j',
                    style: AppTextStyles.captionHint.copyWith(
                        color: isLate ? AppColors.error : null,
                        fontWeight: isLate ? FontWeight.w700 : null)),
            ]),
          ])),
          const SizedBox(width: 10),
          Text(
            CurrencyFormatter.format(balance.abs()),
            style: AppTextStyles.label.copyWith(color: color),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right_rounded,
              size: 18, color: AppColors.textHint),
        ]),
      ),
    );
  }
}

/// Réglage du seuil d'ancienneté, en jours.
///
/// Borné 1–365, exactement comme le CHECK posé par hotfix_178. La borne est
/// vérifiée ICI, avant l'envoi : `updateShop` écrit directement dans
/// Supabase, une valeur hors bornes reviendrait donc en erreur brute après
/// un aller-retour réseau, au lieu d'un message immédiat.
class _AlertDaysSheet extends StatefulWidget {
  final int initial;
  const _AlertDaysSheet({required this.initial});
  @override
  State<_AlertDaysSheet> createState() => _AlertDaysSheetState();
}

class _AlertDaysSheetState extends State<_AlertDaysSheet> {
  late final TextEditingController _ctrl;
  String? _error;

  static const _presets = [7, 15, 30, 60, 90];

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initial.toString());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final v = int.tryParse(_ctrl.text.trim());
    if (v == null || v < 1 || v > 365) {
      setState(() => _error = 'Indiquez un nombre de jours entre 1 et 365.');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Seuil d\'alerte',
      icon:  Icons.schedule_rounded,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    'Au-delà de ce délai, une vente encaissée par un '
                    'partenaire et pas encore reversée est signalée — sur '
                    'le tableau de bord et dans cette liste.',
                    style: AppTextStyles.captionHint),
                const SizedBox(height: 14),
                TextField(
                  controller: _ctrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: AppTextStyles.input,
                  decoration: InputDecoration(
                    suffixText: 'jours',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final p in _presets)
                    InkWell(
                      onTap: () => setState(() {
                        _ctrl.text = p.toString();
                        _error = null;
                      }),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: sem.borderSubtle),
                        ),
                        child: Text('$p j', style: AppTextStyles.caption),
                      ),
                    ),
                ]),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: AppTextStyles.caption
                          .copyWith(color: sem.danger)),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44)),
                  child: const Text('Annuler'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('Enregistrer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}
