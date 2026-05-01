import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/autocomplete_text_field.dart';
import '../../../../shared/widgets/blocked_delete_dialog.dart';
import '../../../../shared/widgets/empty_state_widget.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../domain/entities/supplier.dart';

class SuppliersPage extends StatefulWidget {
  final String shopId;
  const SuppliersPage({super.key, required this.shopId});
  @override State<SuppliersPage> createState() => _SuppliersPageState();
}

class _SuppliersPageState extends State<SuppliersPage> {
  List<Supplier> _suppliers = [];

  @override
  void initState() {
    super.initState();
    _load();
    AppDatabase.addListener(_onDbChanged);
  }

  @override
  void dispose() {
    AppDatabase.removeListener(_onDbChanged);
    super.dispose();
  }

  void _onDbChanged(String table, String shopId) {
    if (!mounted) return;
    if (shopId != widget.shopId && shopId != '_all') return;
    if (table == 'suppliers') _load();
  }

  void _load() => setState(() {
    _suppliers = HiveBoxes.suppliersBox.values
        .map((m) => Supplier.fromMap(Map<String, dynamic>.from(m)))
        .where((s) => s.shopId == widget.shopId)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  });

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      shopId: widget.shopId,
      title: 'Fournisseurs',
      isRootPage: false,
      body: _suppliers.isEmpty
          ? EmptyStateWidget(
              icon: Icons.local_shipping_outlined,
              title: 'Aucun fournisseur',
              subtitle: 'Ajoutez vos fournisseurs pour gérer les commandes d\'achat',
              ctaLabel: 'Ajouter un fournisseur',
              onCta: () => _showForm(context),
            )
          : Column(children: [
              // Bouton ajouter
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(children: [
                  Text('${_suppliers.length} fournisseur${_suppliers.length > 1 ? 's' : ''}',
                      style: AppTextStyles.body12Secondary.copyWith(
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => _showForm(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                          color: AppColors.primary, borderRadius: BorderRadius.circular(8)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.add_rounded, size: 15, color: Colors.white),
                        const SizedBox(width: 6),
                        Text('Ajouter', style: AppTextStyles.body12Bold
                            .copyWith(color: Colors.white)),
                      ]),
                    ),
                  ),
                ]),
              ),
              Expanded(child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _suppliers.length,
                itemBuilder: (_, i) => _SupplierCard(
                  supplier: _suppliers[i],
                  onEdit: () => _showForm(context, supplier: _suppliers[i]),
                  onDelete: () => _delete(_suppliers[i]),
                ),
              )),
            ]),
    );
  }

  void _showForm(BuildContext context, {Supplier? supplier}) {
    final nameCtrl    = TextEditingController(text: supplier?.name ?? '');
    final phoneCtrl   = TextEditingController(text: supplier?.phone ?? '');
    final emailCtrl   = TextEditingController(text: supplier?.email ?? '');
    final addressCtrl = TextEditingController(text: supplier?.address ?? '');
    final notesCtrl   = TextEditingController(text: supplier?.notes ?? '');
    final isEdit = supplier != null;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Center(child: Container(width: 36, height: 4,
                decoration: BoxDecoration(color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 16),
            Row(children: [
              Container(width: 34, height: 34,
                  decoration: BoxDecoration(color: AppColors.primarySurface,
                      borderRadius: BorderRadius.circular(9)),
                  child: Icon(Icons.local_shipping_rounded,
                      size: 17, color: AppColors.primary)),
              const SizedBox(width: 10),
              Text(isEdit ? 'Modifier le fournisseur' : 'Nouveau fournisseur',
                  style: AppTextStyles.title16),
            ]),
            const SizedBox(height: 20),
            _F(ctrl: nameCtrl, label: 'Nom *', hint: 'Ex: Distributeur ABC',
                icon: Icons.business_rounded),
            const SizedBox(height: 10),
            _F(ctrl: phoneCtrl, label: 'Téléphone', hint: '+237 6XX XXX XXX',
                icon: Icons.phone_rounded, type: TextInputType.phone),
            const SizedBox(height: 10),
            _F(ctrl: emailCtrl, label: 'Email', hint: 'contact@fournisseur.com',
                icon: Icons.email_rounded, type: TextInputType.emailAddress),
            const SizedBox(height: 10),
            AutocompleteTextField(
              controller:  addressCtrl,
              label:       'Adresse',
              hint:        'Ville, quartier...',
              prefixIcon:  Icons.location_on_rounded,
              suggestions: _suppliers
                  .map((s) => s.address ?? '')
                  .where((a) => a.isNotEmpty)
                  .toSet()
                  .toList(),
            ),
            const SizedBox(height: 10),
            _F(ctrl: notesCtrl, label: 'Notes', hint: 'Informations supplémentaires...',
                icon: Icons.notes_rounded),
            const SizedBox(height: 20),
            SizedBox(width: double.infinity, height: 46,
              child: ElevatedButton.icon(
                onPressed: () {
                  if (nameCtrl.text.trim().isEmpty) return;
                  final s = Supplier(
                    id: supplier?.id ?? 'sup_${DateTime.now().millisecondsSinceEpoch}',
                    shopId: widget.shopId,
                    name: nameCtrl.text.trim(),
                    phone: phoneCtrl.text.trim().isEmpty ? null : phoneCtrl.text.trim(),
                    email: emailCtrl.text.trim().isEmpty ? null : emailCtrl.text.trim(),
                    address: addressCtrl.text.trim().isEmpty ? null : addressCtrl.text.trim(),
                    notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
                    createdAt: supplier?.createdAt ?? DateTime.now(),
                  );
                  HiveBoxes.suppliersBox.put(s.id, s.toMap());
                  AppDatabase.notifyProductChange(widget.shopId);
                  ActivityLogService.log(
                    action:      isEdit
                        ? 'supplier_updated'
                        : 'supplier_created',
                    targetType:  'supplier',
                    targetId:    s.id,
                    targetLabel: s.name,
                    shopId:      widget.shopId,
                    details: {
                      if ((s.phone   ?? '').isNotEmpty) 'phone':   s.phone,
                      if ((s.email   ?? '').isNotEmpty) 'email':   s.email,
                      if ((s.address ?? '').isNotEmpty) 'city':    s.address,
                    },
                  );
                  Navigator.of(ctx).pop();
                  _load();
                  AppSnack.success(context, isEdit ? 'Fournisseur modifié' : 'Fournisseur ajouté');
                },
                icon: Icon(isEdit ? Icons.check_rounded : Icons.add_rounded, size: 18),
                label: Text(isEdit ? 'Enregistrer' : 'Ajouter'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                  elevation: 0, shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _delete(Supplier s) async {
    // Règle métier : protéger contre la suppression d'un fournisseur référencé.
    final usedByOrders = HiveBoxes.purchaseOrdersBox.values.any((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      return m['supplier_id'] == s.id;
    });
    final usedByReceptions = HiveBoxes.receptionsBox.values.any((raw) {
      final m = Map<String, dynamic>.from(raw as Map);
      return m['supplier_id'] == s.id;
    });
    if (usedByOrders || usedByReceptions) {
      final choice = await showBlockedDeleteDialog(
        context,
        itemLabel: s.name,
        reason: 'Ce fournisseur est utilisé par des commandes fournisseur '
            'ou des réceptions.',
        archiveDescription:
            'Le fournisseur sera marqué inactif — il n\'apparaîtra plus '
            'dans les sélecteurs, mais l\'historique reste intact.',
      );
      if (choice == BlockedDeleteChoice.archive) {
        final archived = Supplier(
          id: s.id, shopId: s.shopId, name: s.name,
          phone: s.phone, email: s.email, address: s.address,
          notes: s.notes, isActive: false,
          createdAt: s.createdAt,
        );
        await HiveBoxes.suppliersBox.put(archived.id, archived.toMap());
        _load();
        if (mounted) AppSnack.success(context, 'Fournisseur archivé');
      }
      return;
    }
    final confirmed = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer le fournisseur',
      description: 'Cette action est irréversible.',
      consequences: const [
        'Le fournisseur disparaît définitivement de la liste.',
        'L\'historique passé reste lisible mais le nom ne peut plus être réutilisé.',
      ],
      confirmText: s.name,
      onConfirmed: () {},
    );
    if (confirmed != true || !mounted) return;
    await HiveBoxes.suppliersBox.delete(s.id);
    await ActivityLogService.log(
      action:      'supplier_deleted',
      targetType:  'supplier',
      targetId:    s.id,
      targetLabel: s.name,
      shopId:      widget.shopId,
      details: {
        if ((s.phone   ?? '').isNotEmpty) 'phone':   s.phone,
        if ((s.email   ?? '').isNotEmpty) 'email':   s.email,
        if ((s.address ?? '').isNotEmpty) 'city':    s.address,
      },
    );
    _load();
    if (mounted) AppSnack.success(context, 'Fournisseur supprimé');
  }
}

class _SupplierCard extends StatelessWidget {
  final Supplier supplier;
  final VoidCallback onEdit, onDelete;
  const _SupplierCard({required this.supplier, required this.onEdit,
    required this.onDelete});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.surface, borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.divider)),
    child: Row(children: [
      Container(width: 38, height: 38,
          decoration: BoxDecoration(color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(9)),
          child: Icon(Icons.local_shipping_rounded, size: 18,
              color: AppColors.primary)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(supplier.name, style: AppTextStyles.body13Bold),
        if (supplier.phone != null)
          Text(supplier.phone!, style: AppTextStyles.caption11Hint),
      ])),
      IconButton(icon: const Icon(Icons.edit_outlined, size: 16),
          onPressed: onEdit, color: AppColors.textSecondary,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
      IconButton(icon: const Icon(Icons.delete_outline, size: 16),
          onPressed: onDelete, color: AppColors.error,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
    ]),
  );
}

class _F extends StatelessWidget {
  final TextEditingController ctrl;
  final String label, hint;
  final IconData icon;
  final TextInputType type;
  const _F({required this.ctrl, required this.label, required this.hint,
    required this.icon, this.type = TextInputType.text});
  @override
  Widget build(BuildContext context) => TextField(
    controller: ctrl,
    keyboardType: type,
    style: AppTextStyles.body13,
    decoration: InputDecoration(
      labelText: label, hintText: hint,
      labelStyle: AppTextStyles.body12Secondary,
      hintStyle: AppTextStyles.body12Secondary
          .copyWith(color: AppColors.textHint),
      prefixIcon: Icon(icon, size: 16, color: AppColors.textHint),
      filled: true, fillColor: AppColors.inputFill, isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.inputBorder)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.inputBorder)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
    ),
  );
}
