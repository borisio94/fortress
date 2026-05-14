import 'package:flutter/material.dart';

import '../../../../core/database/app_database.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/adaptive_form_frame.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../crm/domain/entities/client.dart';
import '../../../crm/presentation/pages/clients_page.dart' show ClientFormSheet;

/// Résultat du sheet "Enregistrer commande" (sprint UX commande).
/// Capture les 3 informations minimales pour qu'une commande puisse être
/// enregistrée en statut `scheduled` :
///   * Le client (sélectionné ou créé)
///   * La date de livraison souhaitée
///   * Le lieu de livraison (ville + quartier), pré-rempli depuis le client
///     mais modifiable. Le snapshot reste figé sur la commande, et la
///     fiche client est mise à jour silencieusement à la nouvelle adresse
///     si modifiée (cf. _onSaveOrder dans le bloc).
class OrderCreationResult {
  final Client    client;
  final DateTime? scheduledAt;
  final String?   deliveryCity;
  final String?   deliveryAddress;
  /// Date à laquelle la commande a été effectivement passée. Par défaut
  /// `DateTime.now()`. Antidatable (sans limite passée) pour permettre la
  /// saisie de ventes effectuées hors-ligne / oubliées / en retard.
  /// Maps sur `Sale.createdAt` côté bloc.
  final DateTime  createdAt;
  const OrderCreationResult({
    required this.client,
    required this.scheduledAt,
    required this.deliveryCity,
    required this.deliveryAddress,
    required this.createdAt,
  });
}

/// Helper d'ouverture standardisé.
Future<OrderCreationResult?> showOrderCreationSheet(
  BuildContext context, {
  required String shopId,
  Client?   initialClient,
  DateTime? initialDate,
  String?   initialCity,
  String?   initialAddress,
  DateTime? initialCreatedAt,
}) {
  return showFormSheet<OrderCreationResult>(
    context: context,
    builder: (_) => _OrderCreationSheet(
      shopId:           shopId,
      initialClient:    initialClient,
      initialDate:      initialDate,
      initialCity:      initialCity,
      initialAddress:   initialAddress,
      initialCreatedAt: initialCreatedAt,
    ),
  );
}

class _OrderCreationSheet extends StatefulWidget {
  final String shopId;
  final Client?   initialClient;
  final DateTime? initialDate;
  final String?   initialCity;
  final String?   initialAddress;
  final DateTime? initialCreatedAt;
  const _OrderCreationSheet({
    required this.shopId,
    this.initialClient,
    this.initialDate,
    this.initialCity,
    this.initialAddress,
    this.initialCreatedAt,
  });
  @override
  State<_OrderCreationSheet> createState() => _OrderCreationSheetState();
}

class _OrderCreationSheetState extends State<_OrderCreationSheet> {
  Client? _client;
  DateTime? _date;
  // Date à laquelle la commande est effectivement passée. Default = now.
  // Antidatable sans limite passée (pour rattrapage de ventes hors-ligne /
  // saisie tardive / clôture comptable). PAS dans le futur (sinon ce
  // serait une commande programmée, capturée par _date).
  late DateTime _createdAt;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _addressCtrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client    = widget.initialClient;
    _date      = widget.initialDate;
    _createdAt = widget.initialCreatedAt ?? DateTime.now();
    _cityCtrl    = TextEditingController(
        text: widget.initialCity ?? widget.initialClient?.city ?? '');
    _addressCtrl = TextEditingController(
        text: widget.initialAddress ?? widget.initialClient?.district ?? '');
  }

  @override
  void dispose() {
    _cityCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickClient() async {
    final picked = await showModalBottomSheet<Client>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _MiniClientPicker(shopId: widget.shopId),
    );
    if (picked != null && mounted) {
      setState(() {
        _client = picked;
        // Si l'utilisateur n'a pas explicitement saisi, pré-remplir avec
        // les coords du client fraîchement choisi.
        if (_cityCtrl.text.trim().isEmpty && (picked.city ?? '').isNotEmpty) {
          _cityCtrl.text = picked.city!;
        }
        if (_addressCtrl.text.trim().isEmpty
            && (picked.district ?? '').isNotEmpty) {
          _addressCtrl.text = picked.district!;
        }
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _date ?? now.add(const Duration(hours: 2));
    // Antidatable : firstDate = DateTime(2020) pour permettre de
    // numériser une livraison passée (commande déjà livrée avant
    // l'inscription Fortress). lastDate +365j pour garder la possibilité
    // de programmer une livraison future jusqu'à 1 an.
    final d = await showDatePicker(
      context:    context,
      initialDate: initial.isBefore(DateTime(2020))
          ? DateTime(2020)
          : initial,
      firstDate:  DateTime(2020),
      lastDate:   now.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context:    context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (t == null || !mounted) return;
    setState(() {
      _date = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    });
  }

  /// Picker pour la date d'émission de la commande (antidatage possible).
  /// Bornes : firstDate très ancienne (pas de limite passé demandée par
  /// l'utilisateur), lastDate = maintenant (pas de futur ici — pour les
  /// commandes futures, utiliser `_pickDate` qui set `scheduledAt`).
  Future<void> _pickCreatedAt() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context:    context,
      initialDate: _createdAt,
      firstDate:  DateTime(2000),
      lastDate:   now,
    );
    if (d == null || !mounted) return;
    final t = await showTimePicker(
      context:    context,
      initialTime: TimeOfDay.fromDateTime(_createdAt),
    );
    if (t == null || !mounted) return;
    var picked = DateTime(d.year, d.month, d.day, t.hour, t.minute);
    // Garde-fou : si l'utilisateur sélectionne aujourd'hui + une heure
    // future, on clampe à maintenant (sinon la commande serait dans le
    // futur, ce qui contredit la sémantique createdAt).
    if (picked.isAfter(now)) picked = now;
    setState(() => _createdAt = picked);
  }

  void _confirm() {
    // Tous les champs sont obligatoires pour qu'une commande soit
    // exploitable côté logistique : sans client → impossible de livrer ;
    // sans date → pas de planning ; sans ville/quartier → adresse vide.
    if (_client == null) {
      setState(() => _error = 'Sélectionne un client.');
      return;
    }
    if (_date == null) {
      setState(() => _error = 'Choisis la date et l\'heure de livraison.');
      return;
    }
    final city    = _cityCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    if (city.isEmpty) {
      setState(() => _error = 'Renseigne la ville de livraison.');
      return;
    }
    if (address.isEmpty) {
      setState(() => _error = 'Renseigne le quartier de livraison.');
      return;
    }
    Navigator.of(context).pop(OrderCreationResult(
      client:          _client!,
      scheduledAt:     _date,
      deliveryCity:    city,
      deliveryAddress: address,
      createdAt:       _createdAt,
    ));
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} à '
        '${two(d.hour)}:${two(d.minute)}';
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: 'Enregistrer la commande',
      icon:  Icons.shopping_bag_outlined,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _SectionLabel('Client'),
                _PickerTile(
                  icon:  Icons.person_outline_rounded,
                  label: _client?.name ?? 'Choisir / créer un client',
                  hint:  _client?.phone,
                  onTap: _pickClient,
                  highlight: _client != null,
                ),
                const SizedBox(height: 14),
                _SectionLabel('Date de la commande'),
                _PickerTile(
                  icon:  Icons.history_rounded,
                  label: _fmtDate(_createdAt),
                  hint:  _isToday(_createdAt)
                      ? 'Aujourd\'hui (par défaut)'
                      : 'Antidatée',
                  onTap: _pickCreatedAt,
                  highlight: !_isToday(_createdAt),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Date de livraison souhaitée'),
                _PickerTile(
                  icon:  Icons.event_outlined,
                  label: _date == null
                      ? 'Choisir la date et l\'heure'
                      : _fmtDate(_date!),
                  onTap: _pickDate,
                  trailing: _date == null
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          onPressed: () => setState(() => _date = null),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 28, minHeight: 28),
                        ),
                ),
                const SizedBox(height: 14),
                _SectionLabel('Lieu de livraison'),
                _LabeledField(
                  label: 'Ville',
                  controller: _cityCtrl,
                  hint: 'Douala',
                ),
                const SizedBox(height: 8),
                _LabeledField(
                  label: 'Quartier / adresse',
                  controller: _addressCtrl,
                  hint: 'Bonapriso',
                ),
                const SizedBox(height: 4),
                Text(
                  'Pré-rempli depuis la fiche client. Si modifié, la fiche '
                  'sera mise à jour ; cette commande conservera l\'adresse '
                  'exacte saisie ici.',
                  style: TextStyle(fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.55)),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!,
                      style: TextStyle(fontSize: 11, color: sem.danger)),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44)),
                  child: const Text('Annuler'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _confirm,
                  icon: const Icon(Icons.check_circle_outline_rounded,
                      size: 18),
                  label: const Text('Enregistrer'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 44),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ─── Helpers UI privés ─────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label.toUpperCase(),
            style: TextStyle(
                fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5,
                color: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: 0.55))),
      );
}

class _PickerTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? hint;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool highlight;
  const _PickerTile({
    required this.icon, required this.label, this.hint,
    required this.onTap, this.trailing, this.highlight = false,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sem   = theme.semantic;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: highlight ? sem.brandSurface : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: highlight ? sem.brand.withValues(alpha: 0.35)
                               : sem.borderSubtle),
        ),
        child: Row(children: [
          Icon(icon, size: 18,
              color: highlight ? sem.brand : const Color(0xFF6B7280)),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
                    color: highlight ? sem.brandText : const Color(0xFF111827))),
            if (hint != null && hint!.isNotEmpty) ...[
              const SizedBox(height: 1),
              Text(hint!,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF6B7280))),
            ],
          ])),
          if (trailing != null) trailing!
          else const Icon(Icons.chevron_right_rounded,
              size: 18, color: Color(0xFF9CA3AF)),
        ]),
      ),
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  const _LabeledField({
    required this.label, required this.hint, required this.controller,
  });
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.divider)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: AppColors.divider)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      ),
    );
  }
}

// ─── Mini picker client (recherche + bouton créer) ─────────────────────────

class _MiniClientPicker extends StatefulWidget {
  final String shopId;
  const _MiniClientPicker({required this.shopId});
  @override
  State<_MiniClientPicker> createState() => _MiniClientPickerState();
}

class _MiniClientPickerState extends State<_MiniClientPicker> {
  String _query = '';
  List<Client> _clients = [];

  @override
  void initState() {
    super.initState();
    _clients = AppDatabase.getClientsForShop(widget.shopId);
  }

  List<Client> get _filtered => _query.isEmpty
      ? _clients
      : _clients.where((c) =>
          c.name.toLowerCase().contains(_query.toLowerCase()) ||
          (c.phone?.contains(_query) ?? false)).toList();

  Future<void> _createNew() async {
    final picker = Navigator.of(context); // capture avant push
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (formCtx) => ClientFormSheet(
        shopId: widget.shopId,
        onSaved: () {
          // ClientFormSheet a déjà sauvegardé via AppDatabase.saveClient.
          // Récupère le dernier client créé pour le retourner au picker.
          Navigator.of(formCtx).pop();
          final all = AppDatabase.getClientsForShop(widget.shopId);
          if (all.isEmpty) return;
          final newest = all.reduce((a, b) =>
              a.createdAt.isAfter(b.createdAt) ? a : b);
          picker.pop(newest);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize:     0.4,
      maxChildSize:     0.95,
      expand: false,
      builder: (_, sc) => Column(children: [
        // Poignée
        Container(margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 36, height: 4,
            decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2))),
        // Titre
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Align(alignment: Alignment.centerLeft,
            child: Text('Sélectionner un client',
                style: TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827))),
          ),
        ),
        // Recherche + bouton + sur la MÊME LIGNE
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Row(children: [
            Expanded(child: TextField(
              onChanged: (v) => setState(() => _query = v),
              keyboardType: TextInputType.phone,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Rechercher par numéro ou nom…',
                hintStyle: const TextStyle(
                    color: Color(0xFFBBBBBB), fontSize: 12),
                prefixIcon: const Icon(Icons.search_rounded,
                    size: 16, color: AppColors.textHint),
                filled: true, fillColor: const Color(0xFFF9FAFB),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.divider)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: AppColors.divider)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(
                        color: AppColors.primary, width: 1.5)),
              ),
            )),
            const SizedBox(width: 8),
            // Icône + pour créer un nouveau client (même ligne que la
            // recherche, comme demandé spec).
            Material(
              color: sem.brand,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _createNew,
                child: Container(
                  width: 40, height: 40,
                  alignment: Alignment.center,
                  child: const Icon(Icons.add_rounded,
                      size: 22, color: Colors.white),
                ),
              ),
            ),
          ]),
        ),
        const Divider(height: 1, color: Color(0xFFF0F0F0)),
        // Liste clients (scroll vertical sur cette zone uniquement)
        Expanded(
          child: _filtered.isEmpty
              ? const Center(child: Text('Aucun client',
                  style: TextStyle(fontSize: 12, color: AppColors.textHint)))
              : ListView.separated(
                  controller: sc,
                  itemCount: _filtered.length,
                  separatorBuilder: (_, __) => const Divider(
                      height: 1, color: Color(0xFFF0F0F0)),
                  itemBuilder: (_, i) {
                    final c = _filtered[i];
                    return ListTile(
                      onTap: () => Navigator.of(context).pop(c),
                      title: Text(c.name,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          [c.phone, c.city, c.district]
                              .whereType<String>()
                              .where((s) => s.isNotEmpty)
                              .join(' · '),
                          style: const TextStyle(fontSize: 11,
                              color: Color(0xFF6B7280))),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

