import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../../../core/services/payment_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/payment.dart';
import '../../domain/mixed_payment.dart';

/// Feuille d'encaissement d'une addition.
///
/// DEUX CHEMINS, ET LE PREMIER NE COÛTE RIEN. Par défaut : choisir le mode,
/// valider. Un tap, comme avant. Le partage est une porte qu'on pousse.
///
/// CE QUI AVAIT ÉTÉ RETIRÉ (2026-08-03), ET CE QUI REVIENT. La feuille
/// demandait le montant reçu, empilait plusieurs règlements et affichait un
/// « reste dû ». Trois reproches lui étaient faits, et deux tiennent
/// toujours : elle imposait une saisie chiffrée à CHAQUE encaissement, et
/// *« le bouton pouvait valider une addition partiellement payée, laissant une
/// créance sans que personne ne l'ait voulu »*.
///
/// Le règlement MIXTE revient, l'ACOMPTE non. Un client qui paie 4 000 en
/// espèces et le reste en MTN est le cas courant ici ; un client qui paie la
/// moitié et s'en va est une créance, et l'addition n'est pas l'écran où l'on
/// décide d'en ouvrir une. La règle qui les sépare — on ne valide que si le
/// total est couvert — vit dans `mixed_payment.dart`, avec ses tests.
///
/// La saisie chiffrée, elle, n'apparaît QUE dans le chemin partagé.
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
  final _amount = TextEditingController();
  PaymentMode _mode = PaymentMode.cash;

  /// Le caissier a demandé à partager le règlement.
  ///
  /// Tant que c'est faux, la feuille est celle d'avant, au caractère près.
  bool _sharing = false;

  /// Les règlements déjà annoncés, dans l'ordre de saisie — c'est cet ordre
  /// qui décide de ce qui s'impute et de ce qui déborde.
  final List<PaymentEntry> _entries = [];

  @override
  void dispose() {
    _reference.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// Ce qui reste à couvrir, pour pré-remplir le montant du règlement suivant.
  int get _left => mixedPaymentState(due: widget.due, entries: _entries).remaining;

  void _startSharing() {
    setState(() {
      _sharing = true;
      // Le premier règlement part du mode déjà choisi et du montant entier :
      // le caissier n'a qu'à corriger ce que le client donne réellement en
      // espèces, et le reste se déduit.
      _amount.text = widget.due.toString();
    });
  }

  void _addEntry() {
    final n = int.tryParse(_amount.text.trim()) ?? 0;
    if (n <= 0) return;
    setState(() {
      _entries.add(PaymentEntry(
        mode: _mode,
        received: n,
        reference: _reference.text.trim().isEmpty
            ? null
            : _reference.text.trim(),
      ));
      _reference.clear();
      // Le montant suivant se pré-remplit avec ce qui reste : c'est presque
      // toujours la bonne valeur, et c'est le geste qu'on veut rendre gratuit.
      _amount.text = _left > 0 ? _left.toString() : '';
    });
  }

  void _removeEntry(int i) => setState(() {
        _entries.removeAt(i);
        _amount.text = _left > 0 ? _left.toString() : '';
      });

  /// Le chemin simple : un règlement unique et intégral.
  ///
  /// Passer par `PaymentSplit.compute` plutôt que de fabriquer le résultat à
  /// la main garde les appelants inchangés — ils lisent `isSettled`,
  /// `applied`, `change` et `dominantMethod` sans savoir combien de lignes
  /// composaient le règlement.
  void _validateSingle() {
    final ref = _reference.text.trim();
    final split = PaymentSplit.compute(
        widget.due,
        singleEntry(
          due: widget.due,
          mode: _mode,
          reference: ref.isEmpty ? null : ref,
        ));
    Navigator.of(context).pop(split);
  }

  void _validateShared(PaymentSplit split) => Navigator.of(context).pop(split);

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    final state = mixedPaymentState(due: widget.due, entries: _entries);

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
            // ── Les règlements déjà annoncés ───────────────────────────
            if (_entries.isNotEmpty) ...[
              for (var i = 0; i < _entries.length; i++)
                _EntryRow(
                  entry: _entries[i],
                  onRemove: () => _removeEntry(i),
                ),
              const SizedBox(height: 12),
            ],

            Text(_sharing && _entries.isNotEmpty
                    ? 'Règlement suivant'
                    : 'Mode de règlement',
                style: AppTextStyles.caption),
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

            // ── Montant : UNIQUEMENT dans le chemin partagé ────────────
            //
            // C'est le reproche du 2026-08-03 qui tient toujours : un champ
            // chiffré à chaque encaissement transformait un geste en saisie.
            // Il n'apparaît que pour qui a demandé à partager.
            if (_sharing) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Montant reçu',
                  hintText: 'Ce que le client donne par ce moyen',
                ),
              ),
            ],

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

            if (_sharing) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addEntry,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Ajouter ce règlement'),
                ),
              ),
              // ── L'état du partage, en clair ──────────────────────────
              //
              // Le reste dû ou le rendu, jamais les deux : l'un exclut
              // l'autre, et afficher les deux lignes dont une à zéro fait
              // chercher laquelle compte.
              if (state.remaining > 0)
                Text(
                    'Reste à couvrir : '
                    '${CurrencyFormatter.format(state.remaining.toDouble())}',
                    style: AppTextStyles.bodyBold
                        .copyWith(color: sem.warningText))
              else if (state.change > 0)
                Text(
                    'À rendre : '
                    '${CurrencyFormatter.format(state.change.toDouble())}',
                    style: AppTextStyles.bodyBold
                        .copyWith(color: sem.successText)),
            ],

            const SizedBox(height: 18),

            // ── Valider ────────────────────────────────────────────────
            AppPrimaryButton(
              label: 'Valider l\'encaissement',
              icon: Icons.check_rounded,
              fullWidth: true,
              // Dans le chemin simple, il n'y a rien à vérifier : le montant
              // reçu EST le montant dû. Dans le chemin partagé, c'est la règle
              // qui tranche — et elle refuse une addition à moitié réglée.
              enabled: !_sharing || state.canValidate,
              onTap: _sharing
                  ? () => _validateShared(state.split)
                  : _validateSingle,
            ),

            // Un bouton grisé sans raison affichée se lit comme une panne.
            if (_sharing && state.blocker != null) ...[
              const SizedBox(height: 8),
              Text(state.blocker!,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.captionHint
                      .copyWith(color: sem.dangerText)),
            ],

            // ── La porte vers le partage ───────────────────────────────
            if (!_sharing) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: _startSharing,
                icon: const Icon(Icons.call_split_rounded, size: 18),
                label: const Text('Payer en plusieurs fois'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Un règlement déjà annoncé, dans la liste du haut.
class _EntryRow extends StatelessWidget {
  final PaymentEntry entry;
  final VoidCallback onRemove;

  const _EntryRow({required this.entry, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: sem.elevatedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: sem.borderSubtle),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            '${entry.mode.label} · '
            '${CurrencyFormatter.format(entry.received.toDouble())}'
            '${entry.reference == null ? '' : ' · ${entry.reference}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySm,
          ),
        ),
        IconButton(
          tooltip: 'Retirer ce règlement',
          visualDensity: VisualDensity.compact,
          onPressed: onRemove,
          icon: Icon(Icons.close_rounded, size: 18, color: sem.dangerText),
        ),
      ]),
    );
  }
}
