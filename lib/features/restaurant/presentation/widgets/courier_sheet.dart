import 'package:flutter/material.dart';

import '../../../../core/services/staff_service.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/app_field.dart';
import '../../../../shared/widgets/app_primary_button.dart';
import '../../domain/entities/staff_member.dart';

/// Livreur retenu pour une commande : un nom, et le numéro auquel le joindre.
class CourierChoice {
  final String name;
  final String phone;

  /// Ce livreur est-il DÉCLARÉ AU PERSONNEL ?
  ///
  /// La feuille distinguait déjà les deux chemins — choisir une fiche, ou
  /// saisir un nom — mais rendait le même objet dans les deux cas. La
  /// distinction se perdait donc à la sortie.
  ///
  /// Elle décide de ce qu'on propose de lui verser : rien pour un salarié,
  /// dont le coût est déjà dans la paie. Sans ce drapeau, le montant resterait
  /// pré-rempli et la course serait payée deux fois.
  final bool isStaff;

  const CourierChoice({
    required this.name,
    this.phone = '',
    this.isStaff = false,
  });

  /// Ce qui est écrit sur la commande. Nom et téléphone dans une seule chaîne
  /// — `Sale` ne porte pas de colonne dédiée au téléphone du livreur, et en
  /// ajouter une aurait imposé une migration pour une information dont le seul
  /// usage est d'être LUE et composée. Sous cette forme elle apparaît partout
  /// où le livreur est affiché, y compris sur la facture.
  String get label => phone.trim().isEmpty ? name : '$name · ${phone.trim()}';
}

/// ASSIGNER UN LIVREUR à une commande à livrer.
///
/// Deux façons, parce que les deux existent en salle : le livreur habituel,
/// déclaré dans Personnel, et le voisin qu'on dépanne un soir de rush. Le
/// second n'a pas à entrer dans le fichier du personnel — il ne travaille pas
/// ici, il rend service. Son nom et son numéro vivent donc sur la commande,
/// nulle part ailleurs.
///
/// Retourne le livreur retenu, `null` si l'opérateur renonce.
Future<CourierChoice?> showCourierSheet({
  required BuildContext context,
  required String shopId,
  String? current,
}) =>
    showAdaptiveFormSheet<CourierChoice>(
      context: context,
      builder: (_) => _CourierSheet(shopId: shopId, current: current),
    );

class _CourierSheet extends StatefulWidget {
  final String shopId;
  final String? current;

  const _CourierSheet({required this.shopId, this.current});

  @override
  State<_CourierSheet> createState() => _CourierSheetState();
}

class _CourierSheetState extends State<_CourierSheet> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  String? _error;

  /// Personnel dont le poste est « Livreur ». Les autres ne sont pas proposés :
  /// une liste de tout le personnel obligerait à chercher, et rien n'empêche
  /// de saisir un nom à la main pour un cas exceptionnel.
  late final List<StaffMember> _couriers = StaffService.forShop(widget.shopId,
          onlyActive: true)
      .where((s) => StaffMember.isCourierRole(s.role))
      .toList();

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  void _pick(StaffMember s) => Navigator.of(context).pop(CourierChoice(
      name: s.fullName, phone: s.phone ?? '', isStaff: true));

  void _confirmTemporary() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Le nom du livreur est obligatoire.');
      return;
    }
    Navigator.of(context)
        .pop(CourierChoice(name: name, phone: _phoneCtrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sem = Theme.of(context).semantic;

    return AdaptiveFormFrame(
      title: 'Livreur',
      subtitle: widget.current,
      icon: Icons.delivery_dining_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_couriers.isNotEmpty) ...[
              Text('Vos livreurs', style: AppTextStyles.caption),
              const SizedBox(height: 8),
              for (final s in _couriers)
                InkWell(
                  onTap: () => _pick(s),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      Icon(Icons.person_outline_rounded,
                          size: 18, color: cs.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s.fullName,
                                style: AppTextStyles.bodySmBold
                                    .copyWith(color: cs.onSurface)),
                            if ((s.phone ?? '').trim().isNotEmpty)
                              Text(s.phone!.trim(),
                                  style: AppTextStyles.caption),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, size: 18),
                    ]),
                  ),
                ),
              const Divider(height: 22),
            ] else ...[
              Text(
                  'Aucun livreur dans votre personnel. Ajoutez-en un avec le '
                  'poste « Livreur » dans Personnel, ou saisissez ci-dessous '
                  'un livreur de passage.',
                  style: AppTextStyles.captionHint),
              const SizedBox(height: 14),
            ],
            Text('Livreur de passage', style: AppTextStyles.caption),
            const SizedBox(height: 8),
            AppField(
              controller: _nameCtrl,
              hint: 'Nom',
              prefixIcon: Icons.person_outline_rounded,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 10),
            AppField(
              controller: _phoneCtrl,
              hint: '6 XX XX XX XX',
              keyboardType: TextInputType.phone,
              prefixIcon: Icons.phone_outlined,
            ),
            const SizedBox(height: 6),
            Text(
                'Il n\'entre pas dans votre personnel : son nom et son numéro '
                'restent sur cette commande.',
                style: AppTextStyles.captionHint),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: AppTextStyles.caption.copyWith(color: sem.danger)),
            ],
            const SizedBox(height: 16),
            AppPrimaryButton(
              label: 'Assigner ce livreur',
              icon: Icons.check_rounded,
              fullWidth: true,
              onTap: _confirmTemporary,
            ),
          ],
        ),
      ),
    );
  }
}
