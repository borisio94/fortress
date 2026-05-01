import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/sale.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../bloc/caisse_bloc.dart';

/// Sélecteur du mode de livraison à insérer dans le paiement d'une vente.
/// 3 options : retrait en boutique / livraison équipe (nom livreur) /
/// livraison partenaire (dropdown des partenaires actifs).
///
/// Lit et écrit l'état via `CaisseBloc` : la valeur est conservée jusqu'au
/// CompleteSale qui la consomme.
class DeliveryModeSelector extends StatelessWidget {
  final String shopId;
  const DeliveryModeSelector({super.key, required this.shopId});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CaisseBloc, CaisseState>(
      buildWhen: (p, c) =>
          p.deliveryMode       != c.deliveryMode ||
          p.deliveryLocationId != c.deliveryLocationId ||
          p.deliveryPersonName != c.deliveryPersonName,
      builder: (context, state) {
        final mode = state.deliveryMode;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Mode de livraison',
                style: TextStyle(fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A))),
            const SizedBox(height: 12),
            _ModeTile(
              icon: Icons.store_rounded,
              label: 'Retrait en boutique',
              subtitle: 'Le client vient récupérer sa commande',
              color: AppColors.primary,
              selected: mode == DeliveryMode.pickup,
              onTap: () => context.read<CaisseBloc>().add(
                  SetDeliveryMode(mode: DeliveryMode.pickup)),
            ),
            const SizedBox(height: 8),
            _ModeTile(
              icon: Icons.delivery_dining_rounded,
              label: 'Livraison par notre équipe',
              subtitle: 'Un membre ou coursier livre le client',
              color: AppColors.secondary,
              selected: mode == DeliveryMode.inHouse,
              onTap: () => context.read<CaisseBloc>().add(
                  SetDeliveryMode(
                    mode: DeliveryMode.inHouse,
                    personName: state.deliveryPersonName,
                  )),
            ),
            if (mode == DeliveryMode.inHouse) ...[
              const SizedBox(height: 6),
              _PersonNameField(current: state.deliveryPersonName),
            ],
            const SizedBox(height: 8),
            _PartnerSection(
              shopId: shopId,
              selectedLocationId: mode == DeliveryMode.partner
                  ? state.deliveryLocationId : null,
            ),
          ],
        );
      },
    );
  }
}

// ─── Tuile d'un mode ─────────────────────────────────────────────────────────
class _ModeTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _ModeTile({
    required this.icon, required this.label, required this.subtitle,
    required this.color, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: selected ? color.withOpacity(0.08) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? color : const Color(0xFFE5E7EB),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: TextStyle(fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? color : const Color(0xFF0F172A))),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 11,
                      color: Color(0xFF9CA3AF))),
            ],
          ),
        ),
        Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off_rounded,
            size: 16,
            color: selected ? color : const Color(0xFFBBBBBB)),
      ]),
    ),
  );
}

// ─── Champ "nom du livreur" (mode inHouse) ───────────────────────────────────
class _PersonNameField extends StatefulWidget {
  final String? current;
  const _PersonNameField({this.current});
  @override
  State<_PersonNameField> createState() => _PersonNameFieldState();
}

class _PersonNameFieldState extends State<_PersonNameField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.current ?? '');
    _ctrl.addListener(() {
      context.read<CaisseBloc>().add(SetDeliveryMode(
        mode: DeliveryMode.inHouse,
        personName: _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim(),
      ));
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: TextField(
      controller: _ctrl,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: 'Nom du livreur (optionnel)',
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
        prefixIcon: const Icon(Icons.person_outline, size: 15,
            color: Color(0xFFAAAAAA)),
        filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      ),
    ),
  );
}

// ─── Section partenaire ─────────────────────────────────────────────────────
class _PartnerSection extends StatefulWidget {
  final String shopId;
  final String? selectedLocationId;
  const _PartnerSection({required this.shopId, this.selectedLocationId});
  @override
  State<_PartnerSection> createState() => _PartnerSectionState();
}

class _PartnerSectionState extends State<_PartnerSection> {
  List<StockLocation> _partners = [];

  @override
  void initState() {
    super.initState();
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    _partners = AppDatabase.getStockLocationsForOwner(userId)
        .where((l) => l.type == StockLocationType.partner && l.isActive)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_partners.isEmpty) {
      // Pas de partenaires : afficher la tuile désactivée avec un lien
      return _ModeTile(
        icon: Icons.local_shipping_rounded,
        label: 'Livraison partenaire',
        subtitle: 'Aucun dépôt partenaire — Paramètres → Emplacements',
        color: AppColors.textHint,
        selected: false,
        onTap: () {},
      );
    }

    final selected = widget.selectedLocationId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ModeTile(
          icon: Icons.local_shipping_rounded,
          label: 'Livraison partenaire',
          subtitle: selected
              ? 'Via ${_partners.firstWhere(
                  (p) => p.id == widget.selectedLocationId,
                  orElse: () => _partners.first).name}'
              : 'Un dépôt partenaire prend en charge la livraison',
          color: AppColors.warning,
          selected: selected,
          onTap: () {
            // Au premier clic, pré-sélectionner le premier partenaire
            final defaultId = widget.selectedLocationId ?? _partners.first.id;
            context.read<CaisseBloc>().add(SetDeliveryMode(
              mode: DeliveryMode.partner,
              locationId: defaultId,
            ));
          },
        ),
        if (selected) ...[
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: DropdownButtonFormField<String>(
              value: widget.selectedLocationId,
              items: _partners.map((p) => DropdownMenuItem<String>(
                value: p.id,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.local_shipping_rounded,
                      size: 14, color: AppColors.warning),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Text(p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13,
                            color: Color(0xFF0F172A))),
                  ),
                ]),
              )).toList(),
              onChanged: (id) {
                if (id == null) return;
                context.read<CaisseBloc>().add(SetDeliveryMode(
                  mode: DeliveryMode.partner,
                  locationId: id,
                ));
              },
              isDense: true,
              isExpanded: true,
              decoration: InputDecoration(
                filled: true, fillColor: const Color(0xFFF9FAFB),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.primary, width: 1.5)),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
