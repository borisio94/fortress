import 'dart:io';
import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/services/document_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../crm/domain/entities/client.dart';
import '../../domain/entities/product.dart';

/// Dialog 3 étapes : sélection produits → sélection clients → aperçu + envoi.
class ShareCatalogDialog extends StatefulWidget {
  final List<Product> products;
  final String shopId;
  /// Si fourni, pré-sélectionne ces produits et saute à l'étape 2.
  final List<Product>? preSelected;

  const ShareCatalogDialog({
    super.key,
    required this.products,
    required this.shopId,
    this.preSelected,
  });

  static void show(BuildContext context, {
    required List<Product> products,
    required String shopId,
    List<Product>? preSelected,
  }) {
    showDialog(
      context: context,
      builder: (_) => ShareCatalogDialog(
        products: products,
        shopId: shopId,
        preSelected: preSelected,
      ),
    );
  }

  @override
  State<ShareCatalogDialog> createState() => _ShareCatalogDialogState();
}

class _ShareCatalogDialogState extends State<ShareCatalogDialog> {
  int _step = 0; // 0 = produits, 1 = clients, 2 = aperçu
  final _selectedProducts = <String>{};
  final _selectedClients  = <String>{};
  late List<Client> _clients;
  late TextEditingController _messageCtrl;

  @override
  void initState() {
    super.initState();
    _clients = AppDatabase.getClientsForShop(widget.shopId);
    _messageCtrl = TextEditingController();
    if (widget.preSelected != null) {
      for (final p in widget.preSelected!) {
        if (p.id != null) _selectedProducts.add(p.id!);
      }
      if (_selectedProducts.isNotEmpty) _step = 1;
    }
  }

  @override
  void dispose() { _messageCtrl.dispose(); super.dispose(); }

  List<Product> get _pickedProducts => widget.products
      .where((p) => p.id != null && _selectedProducts.contains(p.id))
      .toList();

  List<Client> get _pickedClients => _clients
      .where((c) => _selectedClients.contains(c.id))
      .toList();

  List<Client> get _clientsWithPhone =>
      _clients.where((c) => c.phone != null && c.phone!.isNotEmpty).toList();

  bool get _isDesktop => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  void _goToClients() {
    final msg = DocumentService.buildCatalogMessage(
        _pickedProducts, shopId: widget.shopId);
    _messageCtrl.text = msg;
    setState(() => _step = 1);
  }

  void _goToPreview() {
    if (_messageCtrl.text.isEmpty) {
      final msg = DocumentService.buildCatalogMessage(
          _pickedProducts, shopId: widget.shopId);
      _messageCtrl.text = msg;
    }
    setState(() => _step = 2);
  }

  Future<void> _send() async {
    try {
      await DocumentService.shareToClients(
        products:   _pickedProducts,
        recipients: _pickedClients,
        shopId:     widget.shopId,
        message:    _messageCtrl.text,
      );
      if (mounted) {
        Navigator.of(context).pop();
        AppSnack.success(context, 'Message envoyé');
      }
    } catch (e) {
      if (mounted) AppSnack.error(context, e.toString().split('\n').first);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(children: [
          // Header
          _Header(step: _step, onBack: _step > 0 ? () => setState(() => _step--) : null),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          // Content
          Expanded(child: switch (_step) {
            0 => _ProductStep(
              products: widget.products,
              selected: _selectedProducts,
              onToggle: (id) => setState(() {
                _selectedProducts.contains(id)
                    ? _selectedProducts.remove(id)
                    : _selectedProducts.add(id);
              }),
              onSelectAll: () => setState(() {
                if (_selectedProducts.length == widget.products.length) {
                  _selectedProducts.clear();
                } else {
                  _selectedProducts.addAll(
                      widget.products.map((p) => p.id).whereType<String>());
                }
              }),
            ),
            1 => _ClientStep(
              clients: _clients,
              selected: _selectedClients,
              isDesktop: _isDesktop,
              onToggle: (id) => setState(() {
                _selectedClients.contains(id)
                    ? _selectedClients.remove(id)
                    : _selectedClients.add(id);
              }),
            ),
            _ => _PreviewStep(controller: _messageCtrl),
          }),
          const Divider(height: 1, color: Color(0xFFF0F0F0)),
          // Footer
          Padding(
            padding: const EdgeInsets.all(14),
            child: switch (_step) {
              0 => _FooterBtn(
                label: 'Suivant — ${_selectedProducts.length} produit${_selectedProducts.length > 1 ? 's' : ''}',
                enabled: _selectedProducts.isNotEmpty,
                onTap: _goToClients,
              ),
              1 => _FooterBtn(
                label: 'Aperçu du message',
                enabled: _selectedClients.isNotEmpty || !_isDesktop,
                onTap: _goToPreview,
              ),
              _ => _FooterBtn(
                label: _isDesktop
                    ? 'Envoyer à ${_pickedClients.length} client${_pickedClients.length > 1 ? 's' : ''}'
                    : 'Partager',
                enabled: true,
                onTap: _send,
                icon: Icons.share_rounded,
              ),
            },
          ),
        ]),
      ),
    );
  }
}

// ═══ Header ══════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final int step;
  final VoidCallback? onBack;
  const _Header({required this.step, this.onBack});

  static const _titles = ['Sélectionner les produits', 'Sélectionner les clients', 'Aperçu du message'];
  static const _icons  = [Icons.inventory_2_rounded, Icons.people_rounded, Icons.preview_rounded];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
    child: Row(children: [
      if (onBack != null)
        IconButton(
          onPressed: onBack, icon: const Icon(Icons.arrow_back_rounded, size: 20),
          padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32)),
      Container(
        width: 32, height: 32,
        decoration: BoxDecoration(
            color: AppColors.primarySurface, borderRadius: BorderRadius.circular(8)),
        child: Icon(_icons[step], size: 16, color: AppColors.primary),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(_titles[step],
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)))),
      // Stepper dots
      Row(mainAxisSize: MainAxisSize.min, children: List.generate(3, (i) =>
          Container(
            width: i == step ? 16 : 6, height: 6,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              color: i == step ? AppColors.primary : const Color(0xFFE5E7EB),
              borderRadius: BorderRadius.circular(3)),
          ))),
    ]),
  );
}

// ═══ Étape 1 — Produits ══════════════════════════════════════════════════════

class _ProductStep extends StatelessWidget {
  final List<Product> products;
  final Set<String> selected;
  final ValueChanged<String> onToggle;
  final VoidCallback onSelectAll;
  const _ProductStep({required this.products, required this.selected,
    required this.onToggle, required this.onSelectAll});

  @override
  Widget build(BuildContext context) {
    final allSelected = selected.length == products.length;
    return Column(children: [
      // Tout sélectionner
      InkWell(
        onTap: onSelectAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            Icon(allSelected ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                size: 20, color: AppColors.primary),
            const SizedBox(width: 8),
            Text(allSelected ? 'Tout désélectionner' : 'Tout sélectionner',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.primary)),
            const Spacer(),
            Text('${selected.length}/${products.length}',
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          ]),
        ),
      ),
      const Divider(height: 1),
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: products.length,
        itemBuilder: (_, i) {
          final p = products[i];
          final sel = p.id != null && selected.contains(p.id);
          return InkWell(
            onTap: () { if (p.id != null) onToggle(p.id!); },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Icon(sel ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                    size: 20, color: sel ? AppColors.primary : const Color(0xFFD1D5DB)),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(p.priceSellPos > 0 ? CurrencyFormatter.format(p.priceSellPos) : 'Prix non défini',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
                ])),
                Text('Stock: ${p.totalStock}', style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
              ]),
            ),
          );
        },
      )),
    ]);
  }
}

// ═══ Étape 2 — Clients ═══════════════════════════════════════════════════════

class _ClientStep extends StatelessWidget {
  final List<Client> clients;
  final Set<String> selected;
  final bool isDesktop;
  final ValueChanged<String> onToggle;
  const _ClientStep({required this.clients, required this.selected,
    required this.isDesktop, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    if (clients.isEmpty) {
      return const Center(child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.people_outline_rounded, size: 40, color: Color(0xFFD1D5DB)),
          SizedBox(height: 8),
          Text('Aucun client enregistré', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
        ]),
      ));
    }
    return Column(children: [
      if (isDesktop)
        Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED), borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFDE68A))),
          child: const Row(children: [
            Icon(Icons.info_outline_rounded, size: 14, color: Color(0xFFF59E0B)),
            SizedBox(width: 6),
            Expanded(child: Text('Desktop : max 5 clients par envoi',
                style: TextStyle(fontSize: 11, color: Color(0xFFB45309)))),
          ]),
        ),
      Expanded(child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: clients.length,
        itemBuilder: (_, i) {
          final c = clients[i];
          final hasPhone = c.phone != null && c.phone!.isNotEmpty;
          final sel = selected.contains(c.id);
          return Opacity(
            opacity: hasPhone ? 1.0 : 0.45,
            child: InkWell(
              onTap: hasPhone ? () => onToggle(c.id) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Icon(
                    hasPhone
                        ? (sel ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded)
                        : Icons.phone_disabled_rounded,
                    size: 20,
                    color: sel ? AppColors.primary
                        : hasPhone ? const Color(0xFFD1D5DB) : const Color(0xFFE5E7EB)),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(hasPhone ? c.phone! : 'Pas de numéro',
                        style: TextStyle(fontSize: 11,
                            color: hasPhone ? const Color(0xFF9CA3AF) : const Color(0xFFEF4444))),
                  ])),
                ]),
              ),
            ),
          );
        },
      )),
    ]);
  }
}

// ═══ Étape 3 — Aperçu ════════════════════════════════════════════════════════

class _PreviewStep extends StatelessWidget {
  final TextEditingController controller;
  const _PreviewStep({required this.controller});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: TextField(
      controller: controller,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontSize: 13, height: 1.5),
      decoration: InputDecoration(
        hintText: 'Message catalogue...',
        filled: true,
        fillColor: const Color(0xFFF9FAFB),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      ),
    ),
  );
}

// ═══ Footer button ═══════════════════════════════════════════════════════════

class _FooterBtn extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color? color;
  final IconData? icon;
  const _FooterBtn({required this.label, required this.enabled,
    required this.onTap, this.color, this.icon});

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity, height: 44,
    child: ElevatedButton.icon(
      onPressed: enabled ? onTap : null,
      icon: icon != null ? Icon(icon, size: 16) : const SizedBox.shrink(),
      label: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color ?? AppColors.primary,
        foregroundColor: Colors.white,
        disabledBackgroundColor: const Color(0xFFE5E7EB),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  );
}
