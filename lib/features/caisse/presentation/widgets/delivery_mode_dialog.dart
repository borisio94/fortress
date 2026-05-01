import 'package:flutter/material.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/entities/sale.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';

/// Résultat de la modale de choix du mode de livraison.
class DeliveryModeChoice {
  final DeliveryMode mode;
  final String? locationId;
  final String? personName;
  const DeliveryModeChoice({
    required this.mode, this.locationId, this.personName,
  });
}

/// Affiche une sheet modale pour choisir le mode de livraison au moment où
/// une commande passe à `completed`. Retourne un [DeliveryModeChoice] si
/// l'utilisateur valide, `null` s'il annule.
///
/// Usage typique :
/// ```dart
/// final choice = await askDeliveryMode(context);
/// if (choice == null) return; // annulé → ne pas compléter la commande
/// // ... utiliser choice pour mettre à jour la commande puis changer le statut
/// ```
Future<DeliveryModeChoice?> askDeliveryMode(
    BuildContext context, {
    DeliveryMode? initialMode,
    String? initialLocationId,
    String? initialPersonName,
}) {
  return showModalBottomSheet<DeliveryModeChoice>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => _DeliveryModeSheet(
      initialMode:       initialMode,
      initialLocationId: initialLocationId,
      initialPersonName: initialPersonName,
    ),
  );
}

class _DeliveryModeSheet extends StatefulWidget {
  final DeliveryMode? initialMode;
  final String? initialLocationId;
  final String? initialPersonName;
  const _DeliveryModeSheet({
    this.initialMode, this.initialLocationId, this.initialPersonName,
  });

  @override
  State<_DeliveryModeSheet> createState() => _DeliveryModeSheetState();
}

class _DeliveryModeSheetState extends State<_DeliveryModeSheet> {
  late DeliveryMode _mode;
  String? _locationId;
  late final TextEditingController _personCtrl;
  List<StockLocation> _partners = [];

  @override
  void initState() {
    super.initState();
    _mode       = widget.initialMode ?? DeliveryMode.pickup;
    _locationId = widget.initialLocationId;
    _personCtrl = TextEditingController(text: widget.initialPersonName ?? '');
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    _partners = AppDatabase.getStockLocationsForOwner(userId)
        .where((l) => l.type == StockLocationType.partner && l.isActive)
        .toList();
    // Pré-sélection : si mode partner demandé mais pas de locationId, prendre
    // le premier partenaire dispo.
    if (_mode == DeliveryMode.partner
        && _locationId == null
        && _partners.isNotEmpty) {
      _locationId = _partners.first.id;
    }
  }

  @override
  void dispose() {
    _personCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    // Validation douce : partenaire nécessite une location valide
    if (_mode == DeliveryMode.partner
        && (_locationId == null || _locationId!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choisissez un partenaire de livraison')),
      );
      return;
    }
    Navigator.of(context).pop(DeliveryModeChoice(
      mode:       _mode,
      locationId: _mode == DeliveryMode.partner ? _locationId : null,
      personName: _mode == DeliveryMode.inHouse
          ? (_personCtrl.text.trim().isEmpty ? null : _personCtrl.text.trim())
          : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.80),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(child: Container(width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 12),
              Row(children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.local_shipping_rounded,
                      size: 18, color: AppColors.primary),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Comment la commande est-elle livrée ?',
                      style: TextStyle(fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A))),
                ),
              ]),
              const SizedBox(height: 6),
              const Text(
                  'Le stock sera déduit de la bonne source selon votre choix.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
              const SizedBox(height: 16),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Tile(
                        icon: Icons.store_rounded,
                        label: 'Retrait en boutique',
                        subtitle: 'Le client vient récupérer',
                        color: AppColors.primary,
                        selected: _mode == DeliveryMode.pickup,
                        onTap: () => setState(() {
                          _mode = DeliveryMode.pickup;
                          _locationId = null;
                        }),
                      ),
                      const SizedBox(height: 8),
                      _Tile(
                        icon: Icons.delivery_dining_rounded,
                        label: 'Livraison par notre équipe',
                        subtitle: 'Un membre ou coursier livre',
                        color: AppColors.secondary,
                        selected: _mode == DeliveryMode.inHouse,
                        onTap: () => setState(() {
                          _mode = DeliveryMode.inHouse;
                          _locationId = null;
                        }),
                      ),
                      if (_mode == DeliveryMode.inHouse) ...[
                        const SizedBox(height: 6),
                        _inputField(
                          controller: _personCtrl,
                          hint: 'Nom du livreur (optionnel)',
                          icon: Icons.person_outline,
                        ),
                      ],
                      const SizedBox(height: 8),
                      _Tile(
                        icon: Icons.local_shipping_rounded,
                        label: 'Livraison partenaire',
                        subtitle: _partners.isEmpty
                            ? 'Aucun partenaire — créez-en un dans '
                              'Paramètres → Emplacements'
                            : 'Un dépôt partenaire livre depuis son stock',
                        color: _partners.isEmpty
                            ? AppColors.textHint : AppColors.warning,
                        selected: _mode == DeliveryMode.partner,
                        onTap: _partners.isEmpty
                            ? null
                            : () => setState(() {
                                _mode = DeliveryMode.partner;
                                _locationId ??= _partners.first.id;
                              }),
                      ),
                      if (_mode == DeliveryMode.partner
                          && _partners.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _partnerDropdown(),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 44,
                    child: ElevatedButton.icon(
                      onPressed: _confirm,
                      icon: const Icon(Icons.check_rounded, size: 16),
                      label: const Text('Confirmer'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _partnerDropdown() => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: DropdownButtonFormField<String>(
      value: _locationId,
      items: _partners.map((p) => DropdownMenuItem<String>(
        value: p.id,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.local_shipping_rounded,
              size: 14, color: AppColors.warning),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(p.name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13)),
          ),
        ]),
      )).toList(),
      onChanged: (id) => setState(() => _locationId = id),
      isDense: true, isExpanded: true,
      decoration: InputDecoration(
        filled: true, fillColor: const Color(0xFFF9FAFB),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      ),
    ),
  );

  Widget _inputField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
  }) => Padding(
    padding: const EdgeInsets.only(left: 4),
    child: TextField(
      controller: controller,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
        prefixIcon: Icon(icon, size: 15, color: const Color(0xFFAAAAAA)),
        filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      ),
    ),
  );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label, subtitle;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;
  const _Tile({
    required this.icon, required this.label, required this.subtitle,
    required this.color, required this.selected, this.onTap,
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
                      color: onTap == null
                          ? AppColors.textHint
                          : (selected ? color : const Color(0xFF0F172A)))),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 11,
                      color: Color(0xFF9CA3AF))),
            ],
          ),
        ),
        Icon(
            selected ? Icons.radio_button_checked
                     : Icons.radio_button_off_rounded,
            size: 16,
            color: selected ? color : const Color(0xFFBBBBBB)),
      ]),
    ),
  );
}
