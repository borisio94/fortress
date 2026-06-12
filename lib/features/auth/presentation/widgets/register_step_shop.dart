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
          // Secteur d'activité — masqué en mode e-commerce unique (réversible :
          // kEcommerceOnlyMode). Code conservé pour réactivation future.
          if (!kEcommerceOnlyMode) ...[
            const AppFieldLabel('Type d\'activité', required: true),
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
                fillColor: const Color(0xFFF9FAFB),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: Color(0xFFE5E7EB))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: Color(0xFFE5E7EB))),
              ),
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}
