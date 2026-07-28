import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/permisions/subscription_provider.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../core/services/cash_closure_service.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../domain/entities/cash_closure.dart';
import '../widgets/resto_empty_state.dart';

/// Clôture de caisse AVEUGLE — rapports X et Z (Lot C).
///
/// Règle de conception unique et non négociable : **le total attendu n'est
/// jamais affiché avant validation**. Le caissier compte son tiroir, saisit le
/// montant, et découvre l'écart seulement ensuite. Afficher le total d'abord
/// rendrait tout manquant invisible — il suffirait de recopier le chiffre.
///
/// C'est pourquoi cet écran n'appelle `systemCash` qu'APRÈS la saisie, et que
/// l'historique des écarts est réservé à qui peut voir les finances.
class CashClosurePage extends ConsumerStatefulWidget {
  final String shopId;

  const CashClosurePage({super.key, required this.shopId});

  @override
  ConsumerState<CashClosurePage> createState() => _CashClosurePageState();
}

class _CashClosurePageState extends ConsumerState<CashClosurePage> {
  late final OnDataChanged _listener;
  final _declared = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _listener = (table, sid) {
      if (!mounted) return;
      if (table != 'cash_closures') return;
      if (sid != widget.shopId) return;
      setState(() {});
    };
    AppDatabase.addListener(_listener);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_listener);
    _declared.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _close({required bool isZ}) async {
    final declared = int.tryParse(_declared.text.trim().replaceAll(' ', ''));
    if (declared == null || declared < 0) {
      setState(() => _err = 'Saisissez les espèces comptées.');
      return;
    }

    if (isZ) {
      final ok = await AppConfirmDialog.show(
        context: context,
        icon: Icons.lock_clock_outlined,
        iconColor: Theme.of(context).colorScheme.primary,
        title: 'Clôturer la journée ?',
        body: const Text(
            'Le rapport Z arrête la période : les prochains encaissements '
            'seront comptés dans une nouvelle caisse. Utilisez le contrôle X '
            'pour un simple point de situation.'),
        cancelLabel: 'Annuler',
        confirmLabel: 'Clôturer (Z)',
        onConfirm: () {},
      );
      if (ok != true || !mounted) return;
    }

    setState(() {
      _busy = true;
      _err = null;
    });

    // Le total système n'est calculé qu'ICI : après la saisie, jamais avant.
    final from = CashClosureService.periodStart(widget.shopId);
    final system = CashClosureService.systemCash(widget.shopId, from: from);
    final user = LocalStorageService.getCurrentUser();

    final closure = await CashClosureService.record(
      shopId: widget.shopId,
      declaredCash: declared,
      systemAmount: system,
      isZ: isZ,
      periodFrom: from,
      cashierId: user?.id,
      cashierName: user?.name,
      note: _note.text.trim().isEmpty ? null : _note.text.trim(),
    );

    await ActivityLogService.log(
      action: isZ ? 'cash_closure_z' : 'cash_closure_x',
      targetType: 'cash_closure',
      targetId: closure.id,
      targetLabel: closure.varianceLabel,
      shopId: widget.shopId,
      details: {
        'declared': closure.declaredCash,
        'system': closure.systemCash,
        'variance': closure.variance,
      },
    );

    if (!mounted) return;
    setState(() {
      _busy = false;
      _declared.clear();
      _note.clear();
    });
    await _showResult(closure);
  }

  /// Résultat du comptage — le seul endroit où le total système apparaît.
  Future<void> _showResult(CashClosure c) async {
    final sem = Theme.of(context).semantic;
    final color = c.isBalanced
        ? sem.success
        : (c.isShort ? sem.danger : sem.warning);
    await showAdaptiveFormSheet<void>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: c.isZ ? 'Journée clôturée (Z)' : 'Contrôle de caisse (X)',
        icon: c.isBalanced
            ? Icons.check_circle_outline_rounded
            : Icons.error_outline_rounded,
        iconColor: color,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _line('Espèces comptées', c.declaredCash),
              _line('Attendu en caisse', c.systemCash),
              if (c.openingFloat > 0)
                _line('dont fond de caisse', c.openingFloat, hint: true),
              const Divider(height: 20),
              Row(
                children: [
                  Expanded(
                      child: Text(c.varianceLabel,
                          style: AppTextStyles.bodyBold.copyWith(color: color))),
                  Text(CurrencyFormatter.format(c.gap.toDouble()),
                      style:
                          AppTextStyles.subtitleBold.copyWith(color: color)),
                ],
              ),
              if (!c.isBalanced) ...[
                const SizedBox(height: 6),
                Text(
                    c.isShort
                        ? 'Il manque cette somme dans le tiroir. Vérifiez les '
                            'rendus de monnaie et les sorties d\'espèces.'
                        : 'Le tiroir contient plus que prévu. Un encaissement '
                            'n\'a peut-être pas été enregistré.',
                    style: AppTextStyles.captionHint),
              ],
              const SizedBox(height: 18),
              AppPrimaryButton(
                label: 'Terminé',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: () => Navigator.of(sheetCtx).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String label, int amount, {bool hint = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
                child: Text(label,
                    style: hint
                        ? AppTextStyles.captionHint
                        : AppTextStyles.bodySm)),
            Text(CurrencyFormatter.format(amount.toDouble()),
                style: hint ? AppTextStyles.caption : AppTextStyles.bodySmBold),
          ],
        ),
      );

  Future<void> _editFloat() async {
    final ctrl = TextEditingController(
        text: '${CashClosureService.openingFloat(widget.shopId)}');
    final value = await showAdaptiveFormSheet<int>(
      context: context,
      builder: (sheetCtx) => AdaptiveFormFrame(
        title: 'Fond de caisse',
        icon: Icons.savings_outlined,
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
                'Monnaie laissée dans le tiroir avant le premier encaissement. '
                'Sans elle, la caisse afficherait un excédent de ce montant à '
                'chaque contrôle.',
                style: AppTextStyles.captionHint),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Montant'),
            ),
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Enregistrer',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: () => Navigator.of(sheetCtx)
                  .pop(int.tryParse(ctrl.text.trim()) ?? 0),
            ),
          ]),
        ),
      ),
    );
    if (value == null || !mounted) return;
    await CashClosureService.setOpeningFloat(widget.shopId, value);
    if (!mounted) return;
    setState(() {});
    AppSnack.success(context, 'Fond de caisse enregistré.');
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    // L'historique montre les totaux système : il est réservé à qui peut voir
    // les finances. Un caissier qui le consulterait avant de compter saurait
    // exactement quoi déclarer.
    final canSeeHistory =
        ref.watch(permissionsProvider(widget.shopId)).canViewFinances;
    final closures = CashClosureService.forShop(widget.shopId);
    final from = CashClosureService.periodStart(widget.shopId);
    final float = CashClosureService.openingFloat(widget.shopId);

    return AppScaffold(
      shopId: widget.shopId,
      title: 'Clôture de caisse',
      isRootPage: false,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Saisie aveugle ────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: sem.elevatedSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(Icons.visibility_off_outlined,
                        size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Comptage à l\'aveugle',
                          style: AppTextStyles.bodyBold),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                    'Comptez le tiroir et saisissez le montant. Le total '
                    'attendu ne s\'affichera qu\'après validation — c\'est ce '
                    'qui rend un écart visible.',
                    style: AppTextStyles.captionHint),
                const SizedBox(height: 12),
                TextField(
                  controller: _declared,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Espèces comptées',
                    hintText: 'Total du tiroir',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _note,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note (optionnel)',
                    hintText: 'Écart connu, incident de service…',
                  ),
                ),
                if (_err != null) ...[
                  const SizedBox(height: 8),
                  Text(_err!,
                      style:
                          AppTextStyles.caption.copyWith(color: sem.danger)),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : () => _close(isZ: false),
                        icon: const Icon(Icons.fact_check_outlined, size: 18),
                        label: const Text('Contrôle X'),
                        // Hauteur explicite : le thème impose un minimumSize
                        // infini qui casserait la rangée.
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size(0, 46)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: AppPrimaryButton(
                        label: 'Clôture Z',
                        icon: Icons.lock_clock_outlined,
                        fullWidth: true,
                        isLoading: _busy,
                        onTap: () => _close(isZ: true),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── Période et fond de caisse ─────────────────────────────────
          // Aucun montant d'encaissement ici : ce bloc dit d'OÙ part la
          // période, pas ce qu'elle contient.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: sem.elevatedSurface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: sem.borderSubtle),
            ),
            child: Row(
              children: [
                Icon(Icons.schedule_rounded, size: 16, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Période depuis le ${_stamp(from)}',
                          style: AppTextStyles.bodySm),
                      Text(
                          'Fond de caisse : '
                          '${CurrencyFormatter.format(float.toDouble())}',
                          style: AppTextStyles.captionHint),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _editFloat,
                  child: const Text('Modifier'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Historique (finances seulement) ───────────────────────────
          if (canSeeHistory) ...[
            Text('Derniers contrôles', style: AppTextStyles.bodyBold),
            const SizedBox(height: 8),
            if (closures.isEmpty)
              const RestoEmptyState(
                icon: Icons.point_of_sale_outlined,
                title: 'Aucun contrôle enregistré',
                subtitle: 'Le premier comptage apparaîtra ici.',
              )
            else
              for (final c in closures.take(30))
                _ClosureRow(closure: c),
          ],
        ],
      ),
    );
  }

  static String _stamp(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')} à '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
}

/// Une ligne d'historique : type, date, écart.
class _ClosureRow extends StatelessWidget {
  final CashClosure closure;
  const _ClosureRow({required this.closure});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final color = closure.isBalanced
        ? sem.success
        : (closure.isShort ? sem.danger : sem.warning);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(closure.closureType,
                style: AppTextStyles.bodySmBold.copyWith(color: cs.primary)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                    '${_CashClosurePageState._stamp(closure.closedAt)}'
                    '${(closure.cashierName ?? '').isEmpty ? '' : ' · ${closure.cashierName}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodySm),
                Text(
                    'Compté ${CurrencyFormatter.format(closure.declaredCash.toDouble())}'
                    ' · attendu ${CurrencyFormatter.format(closure.systemCash.toDouble())}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.caption),
                if ((closure.note ?? '').isNotEmpty)
                  Text(closure.note!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.micro),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                  closure.isBalanced
                      ? '—'
                      : '${closure.isShort ? '−' : '+'}'
                          '${CurrencyFormatter.format(closure.gap.toDouble())}',
                  style: AppTextStyles.bodySmBold.copyWith(color: color)),
              Text(closure.varianceLabel,
                  style: AppTextStyles.micro.copyWith(color: color)),
            ],
          ),
        ],
      ),
    );
  }
}
