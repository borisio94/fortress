import 'package:flutter/material.dart';

import '../../../../core/services/payment_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/payment.dart';

/// Feuille d'encaissement d'une addition.
///
/// UN SEUL GESTE : choisir le mode de règlement, valider. L'addition se paie
/// intégralement, en une opération.
///
/// Ce qui a été RETIRÉ (2026-08-03) et pourquoi : la feuille demandait le
/// montant reçu, permettait d'empiler plusieurs règlements et affichait un
/// « reste dû ». Cette mécanique servait l'acompte et le règlement mixte —
/// deux cas qui n'existent pas ici : au comptoir comme en salle, le client
/// règle la totalité d'un coup. Le champ de montant transformait chaque
/// encaissement en saisie chiffrée, et le bouton pouvait valider une addition
/// partiellement payée, laissant une créance sans que personne ne l'ait voulu.
///
/// L'OPÉRATEUR EXACT reste demandé — MTN et Orange sont deux caisses à
/// rapprocher séparément en fin de journée, « Mobile Money » ne suffirait pas.
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
  final _reference = TextEditingController();
  PaymentMode _mode = PaymentMode.cash;

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  void _validate() {
    final ref = _reference.text.trim();
    // Le montant reçu EST le montant dû : un règlement unique et intégral.
    // Passer par `PaymentSplit.compute` plutôt que de fabriquer le résultat à
    // la main garde les appelants inchangés — ils lisent `isSettled`,
    // `applied`, `change` et `dominantMethod` sans savoir combien de lignes
    // composaient le règlement.
    final split = PaymentSplit.compute(widget.due, [
      PaymentEntry(
        mode: _mode,
        received: widget.due,
        reference: ref.isEmpty ? null : ref,
      ),
    ]);
    Navigator.of(context).pop(split);
  }

  @override
  Widget build(BuildContext context) {
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
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ],
            ),
            // Référence FACULTATIVE, et seulement hors espèces : c'est le seul
            // moyen de retrouver un transfert mobile contesté. Laissée vide,
            // elle ne bloque rien — le geste reste « choisir, valider ».
            if (_mode != PaymentMode.cash) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _reference,
                decoration: InputDecoration(
                  labelText: 'Référence (facultatif)',
                  hintText: _mode == PaymentMode.card
                      ? 'N° de ticket'
                      : 'N° de transaction',
                ),
              ),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
              label: 'Valider l\'encaissement',
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
