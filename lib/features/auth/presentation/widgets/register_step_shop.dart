part of '../pages/register_page.dart';

// ─── Step 2 — Boutique ─────────────────────────────────────────────────────
//
// Inclus comme `part of register_page.dart` pour accéder à `_RegisterPageState`
// et aux constantes privées (`_kSectors`, etc.).

class _StepShop extends StatelessWidget {
  final _RegisterPageState state;
  const _StepShop({required this.state});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Votre première boutique', style: AppTextStyles.display),
          const SizedBox(height: 4),
          Text('Vous pourrez en ajouter d\'autres plus tard '
              '(plan Business).',
              style: AppTextStyles.bodySmSecondary),
          const SizedBox(height: 20),
          // Nom boutique
          const AppFieldLabel('Nom de la boutique', required: true),
          AppField(
            controller:  state._shopNameCtrl,
            hint:        'Ex : Mon Shop',
            prefixIcon:  Icons.storefront_rounded,
          ),
          if (state._shopNameError != null)
            _ErrText(state._shopNameError!),
          const SizedBox(height: 14),
          // Type d'établissement — choix DÉFINITIF, non modifiable après
          // création (cf. kCreationSectors dans restaurant_mode.dart).
          //
          // LE DIRE À L'ÉCRAN, et pas seulement ici. `create_shop_page` le
          // disait ; ce tunnel — le chemin RÉEL par lequel une boutique naît —
          // ne le disait pas. Le commerçant choisissait entre « E-commerce »
          // et « Restaurant » sans savoir qu'il ne reviendrait pas dessus, et
          // le découvrait en cherchant le réglage qui n'existe pas.
          //
          // Il y avait ici un `...[` sans condition, vestige d'un
          // `if (!kEcommerceOnlyMode)` retiré. Il ne faisait rien, sinon
          // laisser croire qu'un garde subsistait.
          const AppFieldLabel('Type d\'établissement', required: true),
          DropdownButtonFormField<String>(
            initialValue: state._sector,
            items: _kSectors
                .map((o) => DropdownMenuItem(
                    value: o.value,
                    child: Text(o.label, style: AppTextStyles.body)))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                // ignore: invalid_use_of_protected_member
                state.setState(() => state._sector = v);
              }
            },
            decoration: InputDecoration(
              prefixIcon: Icon(Icons.category_outlined,
                  size: 18, color: AppColors.textSecondary),
              isDense: true,
              filled: true,
              fillColor: AppColors.inputFill,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.divider)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide:
                      BorderSide(color: AppColors.divider)),
            ),
          ),
          // L'avertissement est en `captionHint` et non en `micro` comme
          // ailleurs : dix points pour dire « irréversible », c'est le
          // chuchoter. Il reste calme — l'alarmer à chaque inscription
          // ferait hésiter sur un choix qui, lui, est simple.
          const SizedBox(height: 6),
          Text(
              'Ce choix est définitif : le type d\'établissement ne pourra '
              'plus être modifié après la création.',
              style: AppTextStyles.captionHint),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}
