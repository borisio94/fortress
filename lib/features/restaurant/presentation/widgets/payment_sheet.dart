import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/payment_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/payment.dart';

/// Feuille d'encaissement d'une addition (Lot A).
///
/// Trois choses que la boîte de dialogue « Encaisser ? » ne savait pas faire :
///   * **le rendu monnaie** — le caissier saisit ce que le client tend, l'écran
///     calcule ce qu'il doit rendre. C'est le geste le plus fréquent du
///     service, et le plus facile à rater de tête sur un billet de 10 000 ;
///   * **le règlement mixte** — 5 000 en espèces + le solde en MTN Money, cas
///     courant quand le client n'a pas assez de liquide ;
///   * **l'opérateur exact** — MTN et Orange sont deux caisses à rapprocher
///     séparément en fin de journée, « Mobile Money » ne suffit pas.
///
/// Retourne le [PaymentSplit] validé, ou `null` si le caissier renonce. Cette
/// feuille ne persiste RIEN : c'est l'appelant qui clôture la commande puis
/// enregistre les règlements, pour qu'un échec de clôture ne laisse pas des
/// règlements orphelins derrière lui.
class PaymentSheet extends StatefulWidget {
  /// Montant restant à payer (FCFA).
  final int due;

  /// Repère affiché en sous-titre : nom de table, compte…
  final String? subtitle;

  const PaymentSheet({super.key, required this.due, this.subtitle});

  @override
  State<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  final _entries = <PaymentEntry>[];
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  PaymentMode _mode = PaymentMode.cash;
  String? _err;

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  PaymentSplit get _split => PaymentSplit.compute(widget.due, _entries);

  int get _remaining => _split.remaining;

  void _add() {
    final received = int.tryParse(_amount.text.trim().replaceAll(' ', '')) ?? 0;
    if (received <= 0) {
      setState(() => _err = 'Montant invalide');
      return;
    }
    if (!_mode.allowsChange && received > _remaining) {
      // Un transfert mobile ne se rend pas : accepter le trop-perçu ferait
      // apparaître un encaissement supérieur à l'addition, impossible à
      // rapprocher en fin de journée.
      setState(() => _err = 'Un règlement ${_mode.label} ne peut pas dépasser '
          'le reste dû (${CurrencyFormatter.format(_remaining.toDouble())}).');
      return;
    }
    setState(() {
      _entries.add(PaymentEntry(
        mode: _mode,
        received: received,
        reference: _reference.text.trim().isEmpty
            ? null
            : _reference.text.trim(),
      ));
      _amount.clear();
      _reference.clear();
      _err = null;
    });
  }

  void _removeAt(int i) => setState(() {
        _entries.removeAt(i);
        _err = null;
      });

  void _validate() {
    final split = _split;
    if (split.lines.isEmpty) {
      setState(() => _err = 'Ajoutez au moins un règlement.');
      return;
    }
    Navigator.of(context).pop(split);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final cs = Theme.of(context).colorScheme;
    final split = _split;

    return AdaptiveFormFrame(
      title: 'Encaisser ${CurrencyFormatter.format(widget.due.toDouble())}',
      subtitle: widget.subtitle,
      icon: Icons.payments_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Règlements déjà saisis ────────────────────────────────
            for (var i = 0; i < split.lines.length; i++)
              _LineRow(
                line: split.lines[i],
                onRemove: () => _removeAt(i),
              ),
            if (split.lines.isNotEmpty) const Divider(height: 20),

            // ── Mode ──────────────────────────────────────────────────
            Text('Mode de règlement', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in PaymentMode.selectable)
                  ChoiceChip(
                    label: Text(m.label),
                    selected: _mode == m,
                    onSelected: (_) => setState(() {
                      _mode = m;
                      _err = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Montant ───────────────────────────────────────────────
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: _mode.allowsChange
                    ? 'Montant reçu'
                    : 'Montant transféré',
                hintText: '$_remaining',
                suffixIcon: TextButton(
                  // L'appoint est le cas le plus fréquent : un bouton évite de
                  // retaper un montant que l'écran connaît déjà.
                  onPressed: _remaining <= 0
                      ? null
                      : () => setState(() => _amount.text = '$_remaining'),
                  child: const Text('Appoint'),
                ),
              ),
              onSubmitted: (_) => _add(),
            ),
            if (_mode != PaymentMode.cash) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _reference,
                decoration: InputDecoration(
                  labelText: 'Référence (optionnel)',
                  hintText: _mode == PaymentMode.card
                      ? 'N° de ticket'
                      : 'N° de transaction',
                ),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Ajouter ce règlement'),
              ),
            ),

            // ── Résumé ────────────────────────────────────────────────
            const SizedBox(height: 4),
            _SummaryRow(
                label: 'Encaissé',
                value: CurrencyFormatter.format(split.applied.toDouble())),
            if (split.remaining > 0)
              _SummaryRow(
                label: 'Reste dû',
                value: CurrencyFormatter.format(split.remaining.toDouble()),
                color: sem.warning,
              ),
            if (split.change > 0)
              _SummaryRow(
                label: 'À RENDRE',
                value: CurrencyFormatter.format(split.change.toDouble()),
                color: cs.primary,
                strong: true,
              ),

            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 16),
            AppPrimaryButton(
              label: split.remaining > 0
                  // Le solde non réglé devient une créance client : le dire
                  // avant de valider, pas après.
                  ? 'Encaisser — reste ${CurrencyFormatter.format(split.remaining.toDouble())} dû'
                  : 'Valider l\'encaissement',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _validate,
            ),
          ],
        ),
      ),
    );
  }
}

/// Une ligne de règlement saisie.
class _LineRow extends StatelessWidget {
  final PaymentLine line;
  final VoidCallback onRemove;

  const _LineRow({required this.line, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.mode.label, style: AppTextStyles.bodySmBold),
                if (line.change > 0)
                  Text(
                      'reçu ${CurrencyFormatter.format(line.received.toDouble())} · '
                      'rendu ${CurrencyFormatter.format(line.change.toDouble())}',
                      style: AppTextStyles.micro),
                if ((line.reference ?? '').isNotEmpty)
                  Text('réf. ${line.reference}',
                      style: AppTextStyles.micro),
              ],
            ),
          ),
          Text(CurrencyFormatter.format(line.applied.toDouble()),
              style: AppTextStyles.bodySmBold),
          IconButton(
            onPressed: onRemove,
            icon: Icon(Icons.close_rounded, size: 18, color: sem.danger),
            tooltip: 'Retirer',
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  final bool strong;

  const _SummaryRow({
    required this.label,
    required this.value,
    this.color,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = (strong ? AppTextStyles.subtitleBold : AppTextStyles.bodySm)
        .copyWith(color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
              child: Text(label,
                  style: strong
                      ? AppTextStyles.bodyBold.copyWith(color: color)
                      : AppTextStyles.captionHint)),
          Text(value, style: style),
        ],
      ),
    );
  }
}
