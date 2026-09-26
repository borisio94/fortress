part of 'staff_editor_sheet.dart';

// Les SECTIONS de la fiche employé : des widgets sans état, qui reçoivent
// leurs valeurs et rendent la main par des rappels. L'état (contrôleurs,
// mode, horaire) reste dans `_StaffEditorState`. Extraites le 26/09/2026
// (lot « classes géantes »), sous le banc
// `test/widget/staff_editor_sheet_test.dart`.

/// ACCÈS À L'APPLICATION — la question qui commande tout le reste.
///
/// Un veilleur de nuit ou un homme de ménage ne se connectera jamais, mais
/// son salaire, ses heures et ses avances se tiennent ici. Tant que la fiche
/// exigeait de choisir la personne parmi les comptes, ces gens-là étaient
/// tout simplement impossibles à inscrire.
class _AccessModeChoice extends StatelessWidget {
  final bool hasAccount;
  final ValueChanged<bool> onChanged;

  const _AccessModeChoice({required this.hasAccount, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Cette personne utilise-t-elle l\'application ?',
            style: AppTextStyles.caption),
        const SizedBox(height: 6),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
                value: true,
                label: Text('Oui, elle a un compte'),
                icon: Icon(Icons.phone_iphone_rounded, size: 16)),
            ButtonSegment(
                value: false,
                label: Text('Non, personnel seul'),
                icon: Icon(Icons.badge_outlined, size: 16)),
          ],
          selected: {hasAccount},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 6),
        Text(
            hasAccount
                ? 'Elle est choisie parmi les comptes « Accès à l\'app » '
                    '— son nom et sa fonction viennent de son compte.'
                : 'Elle n\'aura ni compte ni mot de passe. Elle apparaît '
                    'dans le personnel, les pointages et la paie.',
            style: AppTextStyles.captionHint),
        const SizedBox(height: 10),
      ],
    );
  }
}

/// HORAIRE PARTICULIER.
///
/// Le boulanger qui part à 11 h, le veilleur qui prend à la fermeture : sans
/// cette surcharge, ils accumuleraient chaque jour des heures supplémentaires
/// imaginaires ou devraient justifier un départ anticipé quotidien.
class _ClosingField extends StatelessWidget {
  /// `HH:mm` propre à la personne, `null` = celui de la boutique.
  final String? closing;
  final VoidCallback onPick;
  final VoidCallback onClear;

  const _ClosingField({
    required this.closing,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: InkWell(
          onTap: onPick,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Fin de service',
              helperText: closing == null
                  ? 'Suit l\'horaire de l\'établissement'
                  : 'Horaire particulier à cette personne',
              suffixIcon: const Icon(Icons.schedule_rounded, size: 18),
            ),
            child: Text(closing ?? 'Comme la boutique',
                style: AppTextStyles.body),
          ),
        ),
      ),
      if (closing != null)
        TextButton(
          onPressed: onClear,
          child: const Text('Retirer'),
        ),
    ]);
  }
}

/// Code de pointage : 4 chiffres, saisis sur la badgeuse, enregistrés
/// chiffrés. Quand un code existe déjà, « Retirer » l'efface sur-le-champ.
class _PinField extends StatelessWidget {
  final TextEditingController controller;

  /// La fiche a-t-elle déjà un code ?
  final bool hasPin;

  /// Efface le code existant (seulement si [hasPin]).
  final VoidCallback onClear;

  const _PinField({
    required this.controller,
    required this.hasPin,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Code de pointage', style: AppTextStyles.caption),
        const SizedBox(height: 2),
        Text(
            hasPin
                ? 'Un code est déjà défini. Saisissez-en un nouveau pour '
                    'le remplacer.'
                : '4 chiffres, saisis sur la badgeuse à l\'entrée du '
                    'personnel. Il est enregistré chiffré.',
            style: AppTextStyles.captionHint),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(4),
          ],
          obscureText: true,
          decoration: InputDecoration(
            labelText: hasPin ? 'Nouveau code' : 'Code',
            hintText: '••••',
            suffixIcon: hasPin
                ? TextButton(
                    onPressed: onClear,
                    child: const Text('Retirer'),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// Sélecteur de jour au gabarit d'un champ de formulaire.
class _DayField extends StatelessWidget {
  final String label;
  final DateTime value;
  final ValueChanged<DateTime> onPick;

  const _DayField(
      {required this.label, required this.value, required this.onPick});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: value,
            // Une mise à pied se régularise parfois après coup, et un congé
            // s'accorde pour le mois prochain : la fenêtre couvre les deux.
            firstDate: DateTime.now().subtract(const Duration(days: 90)),
            lastDate: DateTime.now().add(const Duration(days: 365)),
          );
          if (d != null) onPick(d);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            suffixIcon: const Icon(Icons.calendar_today_rounded, size: 16),
          ),
          child: Text(
              '${value.day.toString().padLeft(2, '0')}/'
              '${value.month.toString().padLeft(2, '0')}/${value.year}',
              style: AppTextStyles.body),
        ),
      );
}

/// Champ en lecture seule — même gabarit qu'un `TextField`, sans la saisie.
class _ReadOnlyField extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyField({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value, style: AppTextStyles.body),
      );
}

/// Choix de la personne parmi les comptes « Accès à l'app » de la boutique.
///
/// Les comptes DÉJÀ inscrits au personnel sont retirés de la liste : les
/// proposer laisserait créer deux fiches pour la même personne, donc deux
/// codes de badge et deux bulletins de paie.
///
/// Un `Consumer` local plutôt qu'une page entière convertie à Riverpod : seule
/// cette portion dépend du provider, et la remonter obligerait à toucher la
/// page, ses trois onglets et leurs états.
class _AccountPicker extends ConsumerWidget {
  final String shopId;
  final String selected;

  /// Le personnel déjà inscrit, réduit au lien et au nom. Voir
  /// `staff_account_link.dart` pour la règle de rapprochement.
  final List<StaffLink> staffLinks;

  /// `(identifiant, nom, fonction)`. L'IDENTIFIANT est le point de ce lot :
  /// sans lui, la fiche ne saurait pas de quel compte elle vient, et deux
  /// homonymes se confondraient à la prochaine ouverture du formulaire.
  ///
  /// La fonction vient du compte et est recopiée sur la fiche : elle n'est
  /// plus choisie deux fois.
  final void Function(String userId, String name, String jobTitle) onSelect;

  const _AccountPicker({
    required this.shopId,
    required this.selected,
    required this.staffLinks,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(employeesProvider(shopId));
    final all = async.valueOrNull ?? const <Employee>[];
    final names = [
      for (final e in all)
        if (e.fullName.trim().isNotEmpty &&
            !accountHasStaffRecord(
                userId: e.userId,
                fullName: e.fullName,
                staff: staffLinks))
          e.fullName.trim(),
    ]..sort();
    // Retrouver le COMPTE à partir du nom choisi : la liste déroulante ne sait
    // rendre qu'une chaîne. Deux homonymes tous deux éligibles restent
    // indiscernables ICI — le premier de la liste l'emporte. C'est une limite
    // de la liste déroulante, pas du rapprochement : dès que l'un des deux a
    // sa fiche, l'autre reste seul proposé.
    Employee? accountFor(String name) {
      for (final e in all) {
        if (e.fullName.trim() == name) return e;
      }
      return null;
    }

    if (async.isLoading && all.isEmpty) {
      return const _ReadOnlyField(
          label: 'Personne', value: 'Chargement des comptes…');
    }
    if (names.isEmpty) {
      // Dire QUOI faire, et où. Une liste vide sans explication ressemble à
      // une panne alors que c'est un état de départ parfaitement normal.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _ReadOnlyField(
              label: 'Personne', value: 'Aucun compte disponible'),
          const SizedBox(height: 6),
          Text(
              all.isEmpty
                  ? 'Créez d\'abord le compte de cette personne dans '
                      '« Accès à l\'app ».'
                  : 'Tous les comptes de la boutique sont déjà inscrits au '
                      'personnel.',
              style: AppTextStyles.captionHint),
        ],
      );
    }
    return AppSelectWidget(
      label: 'Personne',
      required: true,
      items: names,
      value: selected.isEmpty ? null : selected,
      icon: Icons.person_outline_rounded,
      onChanged: (name) {
        final account = accountFor(name);
        if (account == null) return;
        onSelect(account.userId, name, account.jobTitle.trim());
      },
    );
  }
}
