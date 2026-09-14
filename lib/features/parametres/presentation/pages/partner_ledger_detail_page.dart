import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/services/partner_ledger_service.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/widgets/back_dated_picker.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/providers/current_shop_provider.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../inventaire/domain/entities/stock_location.dart';
import '../../domain/entities/partner_ledger_entry.dart';

/// Résout le nom d'un partenaire (StockLocation type=partner) depuis Hive.
/// Top-level pour être partagé par la vue et son wrapper plein écran.
String partnerNameOf(String id) {
  try {
    final raw = HiveBoxes.stockLocationsBox.get(id);
    if (raw == null) return 'Partenaire';
    final loc = StockLocation.fromMap(Map<String, dynamic>.from(raw));
    return loc.name;
  } catch (_) { return 'Partenaire'; }
}

/// Vue réutilisable du livre de comptes d'un partenaire (SANS Scaffold) :
/// - Solde actuel + bandeau "qui doit qui"
/// - Bouton "Enregistrer un versement" (boutique ↔ partenaire)
/// - Historique chronologique des mouvements (commandes + versements)
///
/// Embarquée comme onglet « Solde » du hub partenaire ([PartnerHubDetailPage])
/// ou enveloppée par [PartnerLedgerDetailPage] pour un accès plein écran.
class PartnerLedgerView extends ConsumerStatefulWidget {
  final String shopId;
  final String partnerLocationId;
  const PartnerLedgerView({
    super.key, required this.shopId, required this.partnerLocationId,
  });
  @override
  ConsumerState<PartnerLedgerView> createState() =>
      _PartnerLedgerViewState();
}

class _PartnerLedgerViewState
    extends ConsumerState<PartnerLedgerView> {
  late void Function(String, String) _listener;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (sid != widget.shopId) return;
      if (table == 'partner_ledger_entries') setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    super.dispose();
  }

  String get _partnerName => partnerNameOf(widget.partnerLocationId);

  /// Confirme + supprime une entrée du partner_ledger. Utile pour
  /// corriger une saisie erronée (ex: faux saleCollected créé par le bug
  /// sync amount_paid). Pas de cascade : si l'entrée est liée à une
  /// commande (`orderId`), la commande reste intacte.
  Future<void> _confirmDeleteEntry(PartnerLedgerEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce mouvement ?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.type.labelFr,
                style: AppTextStyles.bodyBold),
            const SizedBox(height: 6),
            Text('Montant : '
                '${entry.amount >= 0 ? '+' : '−'}'
                '${CurrencyFormatter.format(entry.amount.abs())}',
                style: AppTextStyles.bodySm),
            if ((entry.note ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(entry.note!,
                  style: AppTextStyles.captionHint),
            ],
            const SizedBox(height: 10),
            Text(
                'Cette suppression est irréversible et impactera '
                'directement le solde du partenaire.',
                style: AppTextStyles.caption.copyWith(color: AppColors.error)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await PartnerLedgerService.deleteEntry(entry.id, widget.shopId);
    if (mounted) {
      AppSnack.success(context, 'Mouvement supprimé');
    }
  }

  /// Modifie un mouvement existant (montant / note / date, + catégorie si
  /// c'est une charge). Le SIGNE du montant d'origine est conservé pour ne
  /// pas inverser le sens comptable du mouvement (un versement reste un
  /// versement, une charge reste négative, etc.).
  Future<void> _editEntry(PartnerLedgerEntry entry) async {
    final res = await showFormSheet<_EditResult>(
      context: context,
      builder: (_) => _EditEntrySheet(entry: entry),
    );
    if (res == null || !mounted) return;
    final sign = entry.amount < 0 ? -1.0 : 1.0;
    await PartnerLedgerService.updateEntry(
      entryId:   entry.id,
      shopId:    widget.shopId,
      amount:    res.amount.abs() * sign,
      note:      (res.note?.isEmpty ?? true) ? null : res.note,
      createdAt: res.createdAt,
      category:  res.category,
    );
    if (mounted) {
      AppSnack.success(context, 'Mouvement modifié');
    }
  }

  /// Règlement de la boutique VERS le partenaire (paiement des charges /
  /// livraisons / courses refusées qu'on lui doit). Le versement ENTRANT
  /// (partenaire→boutique) a été retiré d'ici : il se fait désormais par
  /// commande, via le bouton bleu « Versement reçu » sur la carte. Le sens
  /// est donc figé à boutique→partenaire. Pré-rempli avec ce que la boutique
  /// doit (solde négatif), ajustable.
  Future<void> _settlePartner(double balance) async {
    final owed = balance < 0 ? balance.abs() : 0.0;
    final res = await showFormSheet<_RemittanceResult>(
      context: context,
      builder: (_) => _RemittanceSheet(
        partnerName: _partnerName,
        lockedDirection: _RemittanceDirection.boutiqueToPartner,
        initialAmount: owed > 0 ? owed : null,
      ),
    );
    if (res == null || !mounted) return;
    // Boutique → partenaire = +amount dans LES DEUX cas : la boutique paie,
    // le solde monte. Un règlement ramène vers 0 une dette de la boutique ;
    // une avance pousse au-delà et crée une créance sur le partenaire. Même
    // arithmétique, deux intentions — seul le `type` les distingue.
    final isAdvance = res.nature == _RemittanceNature.advance;
    await PartnerLedgerService.addEntry(
      shopId:            widget.shopId,
      partnerLocationId: widget.partnerLocationId,
      type:              isAdvance
                            ? PartnerLedgerEntryType.advance
                            : PartnerLedgerEntryType.remittance,
      amount:            res.amount.abs(),
      note:              res.note?.isEmpty == true ? null : res.note,
      createdAt:         res.createdAt,
    );
    if (mounted) {
      AppSnack.success(context,
          isAdvance ? 'Avance enregistrée.' : 'Règlement enregistré.');
    }
  }

  /// Enregistre une charge que la boutique doit au partenaire (hors
  /// livraison réussie) : course refusée, stockage, commission, etc.
  /// amount NÉGATIF (la boutique doit) → augmente la dette dans le ledger.
  /// Le cash ne sortira des Finances qu'au `remittance` négatif réel.
  Future<void> _registerCharge() async {
    final res = await showFormSheet<_ChargeResult>(
      context: context,
      builder: (_) => _ChargeSheet(partnerName: _partnerName),
    );
    if (res == null || !mounted) return;
    await PartnerLedgerService.addEntry(
      shopId:            widget.shopId,
      partnerLocationId: widget.partnerLocationId,
      type:              PartnerLedgerEntryType.partnerCharge,
      category:          res.category,
      amount:            -res.amount.abs(),
      note:              res.note?.isEmpty == true ? null : res.note,
      createdAt:         res.createdAt,
    );
    if (mounted) {
      AppSnack.success(context, 'Charge enregistrée.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = PartnerLedgerService.entriesForShop(widget.shopId,
        partnerLocationId: widget.partnerLocationId);
    final balance = PartnerLedgerService.balanceForPartner(
        widget.shopId, widget.partnerLocationId);
    final sem = Theme.of(context).semantic;
    final partnerOwes = balance > 0;
    final boutiqueOwes = balance < 0;
    final color = partnerOwes
        ? sem.success
        : (boutiqueOwes ? sem.danger : AppColors.textHint);
    final tag = partnerOwes
        ? 'Le partenaire vous doit'
        : (boutiqueOwes
            ? 'Vous devez au partenaire'
            : 'Comptes à jour');
    // Ancienneté de la plus vieille vente encaissée et pas encore reversée.
    // Absente quand tout est couvert, ou quand le solde positif ne tient
    // qu'à une avance consentie — qui n'est pas un retard.
    final ageDays = PartnerLedgerService
        .debtAgeByPartner(widget.shopId)[widget.partnerLocationId];
    final alertDays =
        ref.watch(currentShopProvider)?.partnerDebtAlertDays ?? 30;
    final isLate = ageDays != null && ageDays > alertDays;

    return Column(children: [
        // Bandeau solde
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          color: color.withValues(alpha: 0.06),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tag,
                  style: AppTextStyles.captionBold.copyWith(
                      letterSpacing: 0.4,
                      color: color.withValues(alpha: 0.85))),
              const SizedBox(height: 4),
              Text(
                CurrencyFormatter.format(balance.abs()),
                style: AppTextStyles.display.copyWith(color: color),
              ),
              if (ageDays != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  Icon(Icons.schedule_rounded,
                      size: 13,
                      color: isLate ? AppColors.error : AppColors.textHint),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                        'Plus ancienne vente non reversée : $ageDays j'
                        '${isLate ? ' · au-delà de $alertDays j' : ''}',
                        style: AppTextStyles.caption.copyWith(
                            color: isLate ? AppColors.error : null)),
                  ),
                ]),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(children: [
            Row(children: [
              // « Régler le partenaire » = paiement boutique→partenaire (solde
              // des charges/livraisons dues). Le versement entrant
              // (partenaire→boutique) se fait désormais par commande.
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _settlePartner(balance),
                  icon: const Icon(Icons.south_west_rounded, size: 18),
                  label: const Text('Régler le partenaire'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _registerCharge,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Charge'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: BorderSide(
                        color: AppColors.primary.withValues(alpha: 0.5)),
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ),
            ]),
          ]),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text('Aucun mouvement',
                  style: TextStyle(color: AppColors.textHint)))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => Divider(
                      height: 1, color: Theme.of(context).semantic.borderSubtle),
                  itemBuilder: (_, i) => _MovementTile(
                    entry: entries[i],
                    onEdit: AppDatabase.isSubscriptionFrozen
                        ? null : () => _editEntry(entries[i]),
                    onDelete: AppDatabase.isSubscriptionFrozen
                        ? null : () => _confirmDeleteEntry(entries[i]),
                  ),
                ),
        ),
      ]);
  }
}

/// Page plein écran autonome (route directe `/parametres/partner-accounts`
/// → détail legacy). Le hub partenaire embarque directement
/// [PartnerLedgerView] dans un onglet, sans cet AppBar.
class PartnerLedgerDetailPage extends StatelessWidget {
  final String shopId;
  final String partnerLocationId;
  const PartnerLedgerDetailPage({
    super.key, required this.shopId, required this.partnerLocationId,
  });
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(partnerNameOf(partnerLocationId),
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        body: PartnerLedgerView(
            shopId: shopId, partnerLocationId: partnerLocationId),
      );
}

class _MovementTile extends StatelessWidget {
  final PartnerLedgerEntry entry;
  final VoidCallback?      onEdit;
  final VoidCallback?      onDelete;
  const _MovementTile({required this.entry, this.onEdit, this.onDelete});
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final isPositive = entry.amount >= 0;
    final color = isPositive ? sem.success : sem.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(_iconFor(entry.type), size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, children: [
          Text(
              entry.type == PartnerLedgerEntryType.partnerCharge
                  && entry.category != null
                  ? '${entry.type.labelFr} · ${entry.category!.labelFr}'
                  : entry.type.labelFr,
              style: AppTextStyles.bodyBold),
          if ((entry.note ?? '').isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(entry.note!,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: AppTextStyles.captionHint),
          ],
          const SizedBox(height: 2),
          Text(_fmtDate(entry.createdAt),
              style: AppTextStyles.micro),
        ])),
        const SizedBox(width: 8),
        Text(
          (isPositive ? '+' : '−')
              + CurrencyFormatter.format(entry.amount.abs()),
          style: AppTextStyles.bodyBold.copyWith(color: color),
        ),
        // Menu options — discret (3 points). Modifier + Supprimer.
        if (onEdit != null || onDelete != null) ...[
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: 'Options',
            icon: Icon(Icons.more_vert_rounded,
                size: 18, color: AppColors.textHint),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onSelected: (v) {
              if (v == 'edit') onEdit?.call();
              if (v == 'delete') onDelete?.call();
            },
            itemBuilder: (_) => [
              if (onEdit != null)
                PopupMenuItem(
                  value: 'edit',
                  child: Row(children: [
                    Icon(Icons.edit_outlined,
                        size: 16, color: AppColors.primary),
                    const SizedBox(width: 8),
                    Text('Modifier',
                        style: AppTextStyles.body
                            .copyWith(color: AppColors.primary)),
                  ]),
                ),
              if (onDelete != null)
                PopupMenuItem(
                  value: 'delete',
                  child: Row(children: [
                    Icon(Icons.delete_outline_rounded,
                        size: 16, color: AppColors.error),
                    const SizedBox(width: 8),
                    Text('Supprimer',
                        style: AppTextStyles.body
                            .copyWith(color: AppColors.error)),
                  ]),
                ),
            ],
          ),
        ],
      ]),
    );
  }

  IconData _iconFor(PartnerLedgerEntryType t) => switch (t) {
        PartnerLedgerEntryType.saleCollected => Icons.shopping_bag_outlined,
        PartnerLedgerEntryType.deliveryOwed  => Icons.local_shipping_outlined,
        PartnerLedgerEntryType.remittance    => Icons.payments_outlined,
        PartnerLedgerEntryType.partnerCharge => Icons.receipt_long_outlined,
        PartnerLedgerEntryType.advance       => Icons.savings_outlined,
      };

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}

// ─── Sheet de versement ────────────────────────────────────────────────────

enum _RemittanceDirection { partnerToBoutique, boutiqueToPartner }

/// Nature d'un versement SORTANT (boutique → partenaire). Le mouvement
/// d'argent est le même dans les deux cas, seule l'intention change :
///   * [settlement] SOLDE une dette que la boutique avait envers lui ;
///   * [advance] en CRÉE une à sa charge.
/// Le solde du partenaire est identique — la distinction sert à relire
/// l'historique.
enum _RemittanceNature { settlement, advance }

class _RemittanceResult {
  final double amount;
  final _RemittanceDirection direction;
  final _RemittanceNature nature;
  final String? note;
  /// Date du versement (antidatable). Si null, le caller stamp `now()`.
  final DateTime? createdAt;
  const _RemittanceResult({
    required this.amount, required this.direction,
    this.nature = _RemittanceNature.settlement,
    this.note, this.createdAt,
  });
}

class _RemittanceSheet extends StatefulWidget {
  final String partnerName;
  /// Si fourni, le sens du versement est figé (sélecteur masqué). Utilisé
  /// pour « Régler le partenaire » (boutique→partenaire uniquement) — le
  /// versement entrant (partenaire→boutique) se fait désormais par commande.
  final _RemittanceDirection? lockedDirection;
  /// Montant pré-rempli (ex. ce que la boutique doit au partenaire).
  final double? initialAmount;
  const _RemittanceSheet({
    required this.partnerName,
    this.lockedDirection,
    this.initialAmount,
  });
  @override
  State<_RemittanceSheet> createState() => _RemittanceSheetState();
}

class _RemittanceSheetState extends State<_RemittanceSheet> {
  late _RemittanceDirection _direction =
      widget.lockedDirection ?? _RemittanceDirection.partnerToBoutique;
  _RemittanceNature _nature = _RemittanceNature.settlement;
  final _amountCtrl = TextEditingController();
  final _noteCtrl   = TextEditingController();
  String? _error;
  /// Date du versement (antidatable). Défaut = now(). Modifiable via picker
  /// pour numériser un versement passé.
  DateTime _date = DateTime.now();

  @override
  void initState() {
    super.initState();
    final amt = widget.initialAmount;
    if (amt != null && amt > 0) _amountCtrl.text = amt.toStringAsFixed(0);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final amt = double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    if (amt == null || amt <= 0) {
      setState(() => _error = 'Montant invalide.');
      return;
    }
    Navigator.of(context).pop(_RemittanceResult(
      amount:    amt,
      direction: _direction,
      nature:    _nature,
      note:      _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      createdAt: _date,
    ));
  }

  /// Bascule la nature du versement. Le champ montant est VIDÉ au passage :
  /// il était pré-rempli avec la dette de la boutique, chiffre qui n'a aucun
  /// sens pour une avance. Un montant pré-rempli faux est plus dangereux
  /// qu'un champ vide — il serait validé sans être relu.
  void _setNature(_RemittanceNature n) {
    if (n == _nature) return;
    setState(() {
      _nature = n;
      _amountCtrl.clear();
      _error = null;
    });
  }

  Future<void> _pickDate() async {
    final d = await pickBackDate(
      context: context,
      initial: _date,
      helpText: 'Date du versement',
    );
    if (d != null) setState(() => _date = d);
  }

  @override
  Widget build(BuildContext context) {
    final locked = widget.lockedDirection != null;
    return AdaptiveFormFrame(
      title: !locked
          ? 'Enregistrer un versement'
          : (_nature == _RemittanceNature.advance
              ? 'Avance au partenaire'
              : 'Régler le partenaire'),
      icon:  Icons.payments_outlined,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Sélecteur de sens masqué quand le sens est figé (« Régler
                // le partenaire » = boutique→partenaire uniquement).
                if (!locked) ...[
                  _SectionLabel('Sens du versement'),
                  _DirRow(
                    selected:
                        _direction == _RemittanceDirection.partnerToBoutique,
                    label: '${widget.partnerName} → Boutique',
                    hint:  'Le partenaire vous remet de l\'argent',
                    onTap: () => setState(() =>
                        _direction = _RemittanceDirection.partnerToBoutique),
                  ),
                  _DirRow(
                    selected:
                        _direction == _RemittanceDirection.boutiqueToPartner,
                    label: 'Boutique → ${widget.partnerName}',
                    hint:  'Vous payez le partenaire (frais de livraison…)',
                    onTap: () => setState(() =>
                        _direction = _RemittanceDirection.boutiqueToPartner),
                  ),
                  const SizedBox(height: 14),
                ] else ...[
                  // Le sens est figé (boutique → partenaire) ; ce qui reste
                  // à choisir, c'est l'INTENTION. L'encart figé qui tenait
                  // cette place annonçait « règlement de ce que vous lui
                  // devez » — phrase fausse dès qu'il s'agit d'une avance.
                  const _SectionLabel('Nature du versement'),
                  _DirRow(
                    selected: _nature == _RemittanceNature.settlement,
                    label: 'Règlement d\'une dette',
                    hint:  'Vous payez ce que vous devez à '
                           '${widget.partnerName}',
                    onTap: () => _setNature(_RemittanceNature.settlement),
                  ),
                  _DirRow(
                    selected: _nature == _RemittanceNature.advance,
                    label: 'Avance commerciale',
                    hint:  'Vous versez d\'avance ; '
                           '${widget.partnerName} vous le devra',
                    onTap: () => _setNature(_RemittanceNature.advance),
                  ),
                  const SizedBox(height: 14),
                ],
                _SectionLabel('Montant (FCFA)'),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  style: AppTextStyles.input,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Date du versement'),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.fromBorderSide(
                          BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    ),
                    child: Row(children: [
                      Icon(Icons.event_rounded,
                          size: 14, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            DateFormat('d MMMM yyyy', 'fr_FR')
                                .format(_date),
                            style: AppTextStyles.bodyBold),
                      ),
                      Icon(Icons.edit_calendar_outlined,
                          size: 12,
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.4)),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Note (optionnel)'),
                TextField(
                  controller: _noteCtrl,
                  maxLines: 2,
                  style: AppTextStyles.body,
                  decoration: InputDecoration(
                    hintText: 'N° de reçu, motif…',
                    hintStyle: AppTextStyles.bodySm.copyWith(
                        color: const Color(0xFFBBBBBB)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: AppTextStyles.caption.copyWith(
                          color: Theme.of(context).semantic.danger)),
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

// ─── Sheet de charge (boutique doit au partenaire) ─────────────────────────

class _ChargeResult {
  final double amount;
  final PartnerChargeCategory category;
  final String? note;
  final DateTime? createdAt;
  const _ChargeResult({
    required this.amount, required this.category, this.note, this.createdAt,
  });
}

class _ChargeSheet extends StatefulWidget {
  final String partnerName;
  const _ChargeSheet({required this.partnerName});
  @override
  State<_ChargeSheet> createState() => _ChargeSheetState();
}

class _ChargeSheetState extends State<_ChargeSheet> {
  PartnerChargeCategory _category = PartnerChargeCategory.failedDelivery;
  final _amountCtrl = TextEditingController();
  final _noteCtrl   = TextEditingController();
  String? _error;
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final amt = double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    if (amt == null || amt <= 0) {
      setState(() => _error = 'Montant invalide.');
      return;
    }
    Navigator.of(context).pop(_ChargeResult(
      amount:    amt,
      category:  _category,
      note:      _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
      createdAt: _date,
    ));
  }

  Future<void> _pickDate() async {
    final d = await pickBackDate(
      context: context,
      initial: _date,
      helpText: 'Date de la charge',
    );
    if (d != null) setState(() => _date = d);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Enregistrer une charge',
      icon:  Icons.receipt_long_outlined,
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
                    'Montant que la boutique doit à ${widget.partnerName} '
                    '(hors livraison réussie).',
                    style: TextStyle(
                        fontSize: 11.5, color: AppColors.textHint)),
                const SizedBox(height: 14),
                _SectionLabel('Catégorie'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final c in PartnerChargeCategory.values)
                      InkWell(
                        onTap: () => setState(() => _category = c),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: _category == c
                                ? sem.brandSurface
                                : AppColors.surface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: _category == c
                                    ? sem.brand.withValues(alpha: 0.5)
                                    : sem.borderSubtle),
                          ),
                          child: Text(c.labelFr,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: _category == c
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: _category == c
                                      ? sem.brandText
                                      : Theme.of(context).colorScheme.onSurface)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _SectionLabel('Montant (FCFA)'),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  style: AppTextStyles.input,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Date de la charge'),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.fromBorderSide(
                          BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    ),
                    child: Row(children: [
                      Icon(Icons.event_rounded,
                          size: 14, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            DateFormat('d MMMM yyyy', 'fr_FR')
                                .format(_date),
                            style: AppTextStyles.bodyBold),
                      ),
                      Icon(Icons.edit_calendar_outlined,
                          size: 12,
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.4)),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Note (optionnel)'),
                TextField(
                  controller: _noteCtrl,
                  maxLines: 2,
                  style: AppTextStyles.body,
                  decoration: InputDecoration(
                    hintText: 'Motif, n° de commande refusée…',
                    hintStyle: AppTextStyles.bodySm.copyWith(
                        color: const Color(0xFFBBBBBB)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: AppTextStyles.caption.copyWith(
                          color: Theme.of(context).semantic.danger)),
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

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label.toUpperCase(),
            style: AppTextStyles.microBold.copyWith(
                letterSpacing: 0.5,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.55))),
      );
}

class _DirRow extends StatelessWidget {
  final bool selected;
  final String label;
  final String hint;
  final VoidCallback onTap;
  const _DirRow({
    required this.selected, required this.label,
    required this.hint, required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? sem.brandSurface : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: selected ? sem.brand.withValues(alpha: 0.4)
                              : sem.borderSubtle),
        ),
        child: Row(children: [
          Icon(selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? sem.brand : AppColors.textHint),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: AppTextStyles.body.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? sem.brandText
                                    : Theme.of(context).colorScheme.onSurface)),
            const SizedBox(height: 1),
            Text(hint,
                style: AppTextStyles.captionHint),
          ])),
        ]),
      ),
    );
  }
}

// ─── Sheet d'édition d'un mouvement existant ───────────────────────────────

class _EditResult {
  final double amount;
  final String? note;
  final DateTime createdAt;
  final PartnerChargeCategory? category;
  const _EditResult({
    required this.amount, this.note, required this.createdAt, this.category,
  });
}

class _EditEntrySheet extends StatefulWidget {
  final PartnerLedgerEntry entry;
  const _EditEntrySheet({required this.entry});
  @override
  State<_EditEntrySheet> createState() => _EditEntrySheetState();
}

class _EditEntrySheetState extends State<_EditEntrySheet> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;
  late DateTime _date;
  late PartnerChargeCategory? _category;
  String? _error;

  bool get _isCharge =>
      widget.entry.type == PartnerLedgerEntryType.partnerCharge;

  @override
  void initState() {
    super.initState();
    final a = widget.entry.amount.abs();
    _amountCtrl = TextEditingController(
        text: a == a.roundToDouble() ? a.toStringAsFixed(0) : a.toString());
    _noteCtrl = TextEditingController(text: widget.entry.note ?? '');
    _date     = widget.entry.createdAt;
    _category = widget.entry.category;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final amt =
        double.tryParse(_amountCtrl.text.trim().replaceAll(',', '.'));
    if (amt == null || amt <= 0) {
      setState(() => _error = 'Montant invalide.');
      return;
    }
    Navigator.of(context).pop(_EditResult(
      amount:    amt,
      note:      _noteCtrl.text.trim(),
      createdAt: _date,
      category:  _isCharge ? _category : null,
    ));
  }

  Future<void> _pickDate() async {
    final d = await pickBackDate(
      context: context,
      initial: _date,
      helpText: 'Date du mouvement',
    );
    if (d != null) setState(() => _date = d);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Modifier le mouvement',
      icon:  Icons.edit_outlined,
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
                    'Type : ${widget.entry.type.labelFr} '
                    '(non modifiable)',
                    style: AppTextStyles.caption),
                const SizedBox(height: 14),
                if (_isCharge) ...[
                  _SectionLabel('Catégorie'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in PartnerChargeCategory.values)
                        InkWell(
                          onTap: () => setState(() => _category = c),
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: _category == c
                                  ? sem.brandSurface
                                  : AppColors.surface,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: _category == c
                                      ? sem.brand.withValues(alpha: 0.5)
                                      : sem.borderSubtle),
                            ),
                            child: Text(c.labelFr,
                                style: AppTextStyles.bodySm.copyWith(
                                    fontWeight: _category == c
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: _category == c
                                        ? sem.brandText
                                        : Theme.of(context).colorScheme.onSurface)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                _SectionLabel('Montant (FCFA)'),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  style: AppTextStyles.input,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Date du mouvement'),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.fromBorderSide(
                          BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    ),
                    child: Row(children: [
                      Icon(Icons.event_rounded,
                          size: 14, color: AppColors.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                            DateFormat('d MMMM yyyy', 'fr_FR')
                                .format(_date),
                            style: AppTextStyles.bodyBold),
                      ),
                      Icon(Icons.edit_calendar_outlined,
                          size: 12,
                          color: Theme.of(context).colorScheme.onSurface
                              .withValues(alpha: 0.4)),
                    ]),
                  ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Note (optionnel)'),
                TextField(
                  controller: _noteCtrl,
                  maxLines: 2,
                  style: AppTextStyles.body,
                  decoration: InputDecoration(
                    hintText: 'Motif, n° de reçu…',
                    hintStyle: AppTextStyles.bodySm.copyWith(
                        color: const Color(0xFFBBBBBB)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(
                            color: AppColors.primary, width: 1.5)),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: AppTextStyles.caption.copyWith(
                          color: Theme.of(context).semantic.danger)),
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
