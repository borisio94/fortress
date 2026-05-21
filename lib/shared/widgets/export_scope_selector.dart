import 'package:flutter/material.dart';

import '../../core/services/export_models.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../features/inventaire/domain/entities/stock_location.dart';

/// Bottom-sheet de configuration d'un export — réutilisable pour tous
/// les types (Produits, Commandes, Clients, Logs).
///
/// Choix offerts à l'utilisateur :
///   * **Scope** — Globale (toutes mes boutiques) / Boutique courante /
///     Partenaire (dropdown des emplacements `StockLocationType.partner`).
///   * **Format** — CSV ou PDF (toggle).
/// L'option « Partenaire » se masque si [allowPartner] est `false` ou
/// si la liste passée est vide (CRM par exemple).
///
/// Le selector ne fait AUCUN appel data. Le caller passe la liste des
/// partenaires déjà chargée depuis `stockLocationsBox` (ou autre) et
/// reçoit l'`ExportConfig` validé via `Navigator.pop(context, config)`.
class ExportScopeSelector extends StatefulWidget {
  final ExportType            type;
  final String                shopId;
  final String?               shopName;
  final List<StockLocation>   partnerLocations;
  final bool                  allowPartner;
  /// Formats supportés par le type d'export courant (ex: Clients ne
  /// supporte que CSV en PR-2). Si vide → [ExportFormat.csv] seul.
  final List<ExportFormat>    supportedFormats;

  const ExportScopeSelector({
    super.key,
    required this.type,
    required this.shopId,
    this.shopName,
    this.partnerLocations = const [],
    this.allowPartner = true,
    this.supportedFormats = const [ExportFormat.csv, ExportFormat.pdf],
  });

  /// Helper pour afficher le sheet et récupérer la config choisie.
  /// Retourne `null` si l'utilisateur annule (swipe down ou bouton retour).
  static Future<ExportConfig?> show(
    BuildContext context, {
    required ExportType type,
    required String shopId,
    String? shopName,
    List<StockLocation> partnerLocations = const [],
    bool allowPartner = true,
    List<ExportFormat> supportedFormats = const [
      ExportFormat.csv,
      ExportFormat.pdf,
    ],
  }) {
    return showModalBottomSheet<ExportConfig>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => ExportScopeSelector(
        type: type,
        shopId: shopId,
        shopName: shopName,
        partnerLocations: partnerLocations,
        allowPartner: allowPartner,
        supportedFormats: supportedFormats,
      ),
    );
  }

  @override
  State<ExportScopeSelector> createState() => _ExportScopeSelectorState();
}

enum _ScopeChoice { global, shop, partner }

class _ExportScopeSelectorState extends State<ExportScopeSelector> {
  late _ScopeChoice _scope;
  late ExportFormat _format;
  String? _partnerId;

  @override
  void initState() {
    super.initState();
    // Préselection : Boutique courante par défaut. Si pas de shopId
    // disponible (cas exotique : page exports en mode hub global), on
    // bascule sur Globale.
    _scope = widget.shopId.isEmpty
        ? _ScopeChoice.global
        : _ScopeChoice.shop;
    _format = widget.supportedFormats.isNotEmpty
        ? widget.supportedFormats.first
        : ExportFormat.csv;
    if (widget.partnerLocations.isNotEmpty) {
      _partnerId = widget.partnerLocations.first.id;
    }
  }

  bool get _canValidate {
    if (_scope == _ScopeChoice.partner && _partnerId == null) return false;
    return true;
  }

  ExportConfig _buildConfig() {
    final scope = switch (_scope) {
      _ScopeChoice.global  => const ExportScopeGlobal(),
      _ScopeChoice.shop    => ExportScopeShop(widget.shopId),
      _ScopeChoice.partner => ExportScopePartner(
            shopId: widget.shopId, locationId: _partnerId!),
    };
    final scopeLabel = switch (_scope) {
      _ScopeChoice.global  => 'Toutes mes boutiques',
      _ScopeChoice.shop    => widget.shopName != null
          ? 'Boutique : ${widget.shopName}'
          : 'Boutique',
      _ScopeChoice.partner => () {
          final p = widget.partnerLocations
              .firstWhere((l) => l.id == _partnerId);
          return 'Partenaire : ${p.name}';
        }(),
    };
    return ExportConfig(
      type:       widget.type,
      scope:      scope,
      format:     _format,
      scopeLabel: scopeLabel,
      shopName:   widget.shopName,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(children: [
                Icon(Icons.file_download_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Exporter ${widget.type.labelFr.toLowerCase()}',
                    style: AppTextStyles.subtitleBold.copyWith(
                        color: theme.colorScheme.onSurface),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Choisissez le périmètre et le format.',
                style: AppTextStyles.caption.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.6)),
              ),
            ),
            const SizedBox(height: 12),
            // ── Scope ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(children: [
                // Globale TOUJOURS visible (même si l'utilisateur n'a
                // qu'une seule boutique — « Globale » = tout son
                // périmètre accessible). Le data source agrège
                // simplement la liste des shops du membership.
                _scopeTile(
                  choice:    _ScopeChoice.global,
                  icon:      Icons.public_outlined,
                  title:     'Globale',
                  subtitle:  'Toutes mes boutiques',
                ),
                // Title = nom de la boutique pour identifier
                // explicitement le périmètre (vs « Boutique » générique
                // qui forçait l'utilisateur à lire le subtitle).
                _scopeTile(
                  choice:    _ScopeChoice.shop,
                  icon:      Icons.store_outlined,
                  title:     widget.shopName?.trim().isNotEmpty == true
                      ? widget.shopName!
                      : 'Boutique courante',
                  subtitle:  'Données de cette boutique uniquement',
                ),
                if (widget.allowPartner &&
                    widget.partnerLocations.isNotEmpty)
                  _scopeTile(
                    choice:    _ScopeChoice.partner,
                    icon:      Icons.local_shipping_outlined,
                    title:     'Partenaire',
                    subtitle:  'Dépôt de livraison spécifique',
                    trailing: _scope == _ScopeChoice.partner
                        ? _partnerDropdown(theme)
                        : null,
                  ),
              ]),
            ),
            const SizedBox(height: 16),
            // ── Format ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Format',
                    style: AppTextStyles.captionBold.copyWith(
                        letterSpacing: 0.4,
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.55))),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: widget.supportedFormats
                    .map((f) => Expanded(child: _formatChip(f, theme)))
                    .toList(),
              ),
            ),
            const SizedBox(height: 20),
            // ── Action ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _canValidate
                      ? () => Navigator.of(context).pop(_buildConfig())
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.file_download_rounded),
                  label: Text(
                      'Exporter en ${_format.labelFr}',
                      style: AppTextStyles.label.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scopeTile({
    required _ScopeChoice choice,
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    final selected = _scope == choice;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outline.withValues(alpha: 0.2),
          width: selected ? 1.5 : 1,
        ),
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.06)
            : null,
      ),
      child: Column(
        children: [
          RadioListTile<_ScopeChoice>(
            value: choice,
            groupValue: _scope,
            onChanged: (v) => setState(() => _scope = v ?? _scope),
            activeColor: theme.colorScheme.primary,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            secondary: Icon(icon, color: theme.colorScheme.primary),
            title: Text(title,
                style: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w600)),
            subtitle: Text(subtitle,
                style: AppTextStyles.caption.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.6))),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: trailing,
            ),
        ],
      ),
    );
  }

  Widget _partnerDropdown(ThemeData theme) {
    return DropdownButtonFormField<String>(
      initialValue: _partnerId,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Emplacement partenaire',
        isDense: true,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: 10),
      ),
      items: widget.partnerLocations
          .map((p) => DropdownMenuItem(
                value: p.id,
                child: Text(p.name, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: (v) => setState(() => _partnerId = v),
    );
  }

  Widget _formatChip(ExportFormat f, ThemeData theme) {
    final selected = _format == f;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              f == ExportFormat.csv
                  ? Icons.table_chart_outlined
                  : Icons.picture_as_pdf_outlined,
              size: 16,
              color: selected ? Colors.white : theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Text(f.labelFr,
                style: AppTextStyles.captionBold.copyWith(
                    color: selected
                        ? Colors.white
                        : theme.colorScheme.onSurface)),
          ],
        ),
        selected: selected,
        showCheckmark: false,
        selectedColor: theme.colorScheme.primary,
        backgroundColor: theme.colorScheme.surface,
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.3),
        ),
        onSelected: (_) => setState(() => _format = f),
      ),
    );
  }
}
