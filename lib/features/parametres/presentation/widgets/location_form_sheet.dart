import 'package:flutter/material.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';

/// Sheet bottom pour créer ou modifier un emplacement de stock
/// (warehouse ou partner). Les locations type='shop' ne passent pas par ici.
class LocationFormSheet extends StatefulWidget {
  final StockLocation? existing;
  final StockLocationType defaultType;
  const LocationFormSheet({
    super.key,
    this.existing,
    this.defaultType = StockLocationType.warehouse,
  });

  @override
  State<LocationFormSheet> createState() => _LocationFormSheetState();
}

class _LocationFormSheetState extends State<LocationFormSheet> {
  late TextEditingController _name;
  late TextEditingController _address;
  late TextEditingController _phone;
  late TextEditingController _contact;
  late TextEditingController _notes;
  late StockLocationType _type;
  late bool _active;
  String? _nameError;
  bool _submitting = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name    = TextEditingController(text: e?.name ?? '');
    _address = TextEditingController(text: e?.address ?? '');
    _phone   = TextEditingController(text: e?.phone ?? '');
    _contact = TextEditingController(text: e?.contactName ?? '');
    _notes   = TextEditingController(text: e?.notes ?? '');
    _type    = e?.type ?? widget.defaultType;
    _active  = e?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _phone.dispose();
    _contact.dispose();
    _notes.dispose();
    super.dispose();
  }

  String? _validateName(String v) {
    final s = v.trim();
    if (s.isEmpty) return 'Nom requis';
    if (s.length < 2) return 'Minimum 2 caractères';
    if (s.length > 60) return 'Maximum 60 caractères';
    // Unicité par propriétaire, tous types confondus, insensible à la casse.
    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    final lower = s.toLowerCase();
    final editingId = widget.existing?.id;
    // 1. StockLocations (warehouses/partners + StockLocation type=shop).
    final siblings = AppDatabase.getStockLocationsForOwner(userId);
    final dup = siblings.any((l) =>
        l.id != editingId && l.name.trim().toLowerCase() == lower);
    if (dup) return 'Un emplacement portant ce nom existe déjà';
    // 2. Boutiques (filet : couvre le cas où la StockLocation type=shop
    //    associée n'a pas encore été synchronisée localement).
    final shops = LocalStorageService.getShopsForUser(userId);
    final dupShop = shops.any((sh) =>
        sh.name.trim().toLowerCase() == lower);
    if (dupShop) return 'Une boutique porte déjà ce nom';
    return null;
  }

  Future<void> _submit() async {
    final err = _validateName(_name.text);
    if (err != null) {
      setState(() => _nameError = err);
      return;
    }
    setState(() { _submitting = true; _nameError = null; });

    final userId = LocalStorageService.getCurrentUser()?.id ?? '';
    if (userId.isEmpty) {
      setState(() { _submitting = false; _nameError = 'Connexion requise'; });
      return;
    }

    final loc = (widget.existing ?? StockLocation(
          id: 'loc_${DateTime.now().millisecondsSinceEpoch}_'
              '${_type.key}',
          ownerId: userId,
          type: _type,
          name: _name.text.trim(),
          createdAt: DateTime.now(),
        )).copyWith(
          name:        _name.text.trim(),
          address:     _address.text.trim().isEmpty ? null : _address.text.trim(),
          phone:       _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          contactName: _contact.text.trim().isEmpty ? null : _contact.text.trim(),
          notes:       _notes.text.trim().isEmpty ? null : _notes.text.trim(),
          isActive:    _active,
        );

    try {
      await AppDatabase.saveStockLocation(loc);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        AppSnack.error(context,
            'Erreur lors de l\'enregistrement : ${e.toString().replaceAll('Exception: ', '')}');
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.85),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: Container(width: 36, height: 4,
                    decoration: BoxDecoration(
                        color: const Color(0xFFE5E7EB),
                        borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 14),
                Text(_isEdit
                        ? 'Modifier l\'emplacement'
                        : (_type == StockLocationType.warehouse
                            ? 'Nouveau magasin'
                            : 'Nouveau dépôt partenaire'),
                    style: const TextStyle(fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F172A))),
                const SizedBox(height: 16),

                // Type (verrouillé en édition pour éviter confusion)
                if (!_isEdit) ...[
                  const _Label('Type'),
                  const SizedBox(height: 6),
                  _TypePicker(
                    value: _type,
                    onChanged: (v) => setState(() => _type = v),
                  ),
                  const SizedBox(height: 14),
                ],

                const _Label('Nom', required: true),
                const SizedBox(height: 4),
                _Field(
                  controller: _name,
                  hint: _type == StockLocationType.warehouse
                      ? 'Ex: Magasin Akwa'
                      : 'Ex: Dépôt DHL Douala',
                  icon: Icons.badge_outlined,
                  errorText: _nameError,
                  onChanged: (_) {
                    if (_nameError != null) setState(() => _nameError = null);
                  },
                ),
                const SizedBox(height: 12),

                const _Label('Adresse'),
                const SizedBox(height: 4),
                _Field(
                  controller: _address,
                  hint: 'Rue, quartier, ville',
                  icon: Icons.location_on_outlined,
                ),
                const SizedBox(height: 12),

                const _Label('Téléphone'),
                const SizedBox(height: 4),
                // Même composant que CreateShopPage : sélecteur pays + E.164
                AppField(
                  controller: _phone,
                  isPhone: true,
                  style: AppFieldStyle.filled,
                ),
                const SizedBox(height: 12),

                const _Label('Personne contact'),
                const SizedBox(height: 4),
                _Field(
                  controller: _contact,
                  hint: 'Responsable ou référent sur place',
                  icon: Icons.person_outline_rounded,
                ),
                const SizedBox(height: 12),

                const _Label('Notes'),
                const SizedBox(height: 4),
                _Field(
                  controller: _notes,
                  hint: 'Horaires, contraintes, infos utiles…',
                  icon: Icons.sticky_note_2_outlined,
                  maxLines: 2,
                ),
                const SizedBox(height: 12),

                if (_isEdit)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _active,
                    onChanged: (v) => setState(() => _active = v),
                    title: const Text('Actif',
                        style: TextStyle(fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    subtitle: Text(_active
                            ? 'Disponible dans les sélections'
                            : 'Masqué des sélections',
                        style: const TextStyle(fontSize: 11,
                            color: Color(0xFF9CA3AF))),
                  ),
                const SizedBox(height: 8),

                Row(children: [
                  Expanded(
                    child: TextButton(
                      onPressed: _submitting
                          ? null : () => Navigator.of(context).pop(false),
                      child: const Text('Annuler'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
                      onPressed: _submitting ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _submitting
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : Text(_isEdit ? 'Enregistrer' : 'Créer'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Widgets locaux ──────────────────────────────────────────────────────────
class _Label extends StatelessWidget {
  final String text;
  final bool required;
  const _Label(this.text, {this.required = false});
  @override
  Widget build(BuildContext context) => RichText(
    text: TextSpan(
      style: const TextStyle(fontSize: 11,
          fontWeight: FontWeight.w500, color: Color(0xFF6B7280)),
      children: [
        TextSpan(text: text),
        if (required) const TextSpan(text: ' *',
            style: TextStyle(color: Color(0xFFEF4444),
                fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  const _Field({
    required this.controller,
    required this.hint,
    required this.icon,
    this.maxLines = 1,
    this.keyboardType,
    this.errorText,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    maxLines: maxLines,
    keyboardType: keyboardType,
    onChanged: onChanged,
    style: const TextStyle(fontSize: 13, color: Color(0xFF1A1D2E)),
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
      prefixIcon: Icon(icon, size: 15, color: const Color(0xFFAAAAAA)),
      filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
      contentPadding: const EdgeInsets.symmetric(
          horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      errorText: errorText,
    ),
  );
}

class _TypePicker extends StatelessWidget {
  final StockLocationType value;
  final ValueChanged<StockLocationType> onChanged;
  const _TypePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(
      child: _TypeOption(
        label: 'Magasin',
        icon: Icons.warehouse_rounded,
        color: const Color(0xFF0EA5E9),
        selected: value == StockLocationType.warehouse,
        onTap: () => onChanged(StockLocationType.warehouse),
      ),
    ),
    const SizedBox(width: 8),
    Expanded(
      child: _TypeOption(
        label: 'Dépôt partenaire',
        icon: Icons.local_shipping_rounded,
        color: const Color(0xFFF59E0B),
        selected: value == StockLocationType.partner,
        onTap: () => onChanged(StockLocationType.partner),
      ),
    ),
  ]);
}

class _TypeOption extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _TypeOption({
    required this.label, required this.icon,
    required this.color, required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: selected ? color.withOpacity(0.10) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? color : const Color(0xFFE5E7EB),
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 15,
            color: selected ? color : const Color(0xFF9CA3AF)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? color : const Color(0xFF6B7280))),
        ),
      ]),
    ),
  );
}
