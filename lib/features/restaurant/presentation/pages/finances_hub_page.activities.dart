part of 'finances_hub_page.dart';

// L'onglet Activités.

// ═══════════════════════════════════════════════════════════════════════
//  Base commune d'un onglet (liste + bouton d'ajout + rebuild sur sync)
// ═══════════════════════════════════════════════════════════════════════
class _ActivitiesTab extends StatefulWidget {
  final String shopId;
  const _ActivitiesTab({required this.shopId});
  @override
  State<_ActivitiesTab> createState() => _ActivitiesTabState();
}

class _ActivitiesTabState extends RestoTabState<_ActivitiesTab> {
  @override
  String get table => 'restaurant_activities';
  @override
  String get shopId => widget.shopId;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = ActivityService.forShop(widget.shopId);
    return Column(
      children: [
        headerButton('Activité', () => _edit(null)),
        Expanded(
          child: items.isEmpty
              ? const RestoEmptyState(
                  icon: Icons.category_outlined,
                  title: 'Aucune activité',
                  subtitle:
                      'Ex. Chawarma, Glace, Bar… Regroupez vos secteurs de vente.',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final a = items[i];
                    return RestoCard(
                      onTap: () => _edit(a),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTextStyles.bodyBold
                                      .copyWith(color: cs.onSurface)),
                              Text(
                                  '${a.isStockMode ? 'Mode stock${a.stockThreshold > 0 ? ' · seuil ${a.stockThreshold}' : ''}' : 'Mode recette'}'
                                  ' · ${_stationLabel(a)}',
                                  style: AppTextStyles.caption),
                            ],
                          ),
                        ),
                        RestoPill(a.isStockMode ? 'stock' : 'recette', cs.primary),
                      ]),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Poste explicite, ou celui que le routage déduira du mode — le gérant doit
  /// lire où partiront ses bons, pas s'il a rempli un champ.
  String _stationLabel(RestaurantActivity a) {
    final explicit = ServiceStation.fromKey(a.station);
    if (explicit != null) return explicit.title;
    return a.isStockMode
        ? '${ServiceStation.bar.title} (auto)'
        : '${ServiceStation.cuisine.title} (auto)';
  }

  Future<void> _edit(RestaurantActivity? a) async {
    await showAdaptiveFormSheet<bool>(
      context: context,
      builder: (_) => _ActivityEditor(shopId: widget.shopId, existing: a),
    );
    if (mounted) setState(() {});
  }
}

class _ActivityEditor extends StatefulWidget {
  final String shopId;
  final RestaurantActivity? existing;
  const _ActivityEditor({required this.shopId, this.existing});
  @override
  State<_ActivityEditor> createState() => _ActivityEditorState();
}

class _ActivityEditorState extends State<_ActivityEditor> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _seuil = TextEditingController(
      text: (widget.existing?.stockThreshold ?? 0) == 0
          ? ''
          : '${widget.existing!.stockThreshold}');
  late String _mode = widget.existing?.mode ?? 'stock';

  /// Poste de service. `null` = « Auto », le poste reste déduit du mode —
  /// c'est l'état de toutes les activités créées avant hotfix_144.
  late ServiceStation? _station =
      ServiceStation.fromKey(widget.existing?.station);
  String? _err;
  bool get _isEdit => widget.existing != null;

  @override
  void dispose() {
    _name.dispose();
    _seuil.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _err = 'Nom requis');
      return;
    }
    final seuil = int.tryParse(_seuil.text.trim()) ?? 0;
    if (_isEdit) {
      await ActivityService.update(widget.existing!.copyWith(
        name: name,
        mode: _mode,
        stockThreshold: seuil,
        station: _station?.key,
        // Repasser sur « Auto » doit VRAIMENT détacher le poste : sans ce
        // drapeau, `copyWith` garderait l'ancien (résolution par `??`).
        clearStation: _station == null,
      ));
    } else {
      await ActivityService.create(
          shopId: widget.shopId,
          name: name,
          mode: _mode,
          stockThreshold: seuil,
          station: _station?.key);
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _delete() async {
    final a = widget.existing!;
    // LA CONFIRMATION DIT CE QUE LA SUPPRESSION EMPORTE. Elle n'avait pas de
    // texte : on supprimait « Bar » sans savoir que douze plats y étaient
    // rattachés, ni que leurs ventes passées changeraient de ligne — le
    // secteur d'une vente n'est pas figé, il se relit sur le plat.
    final n = ActivityService.attachedTo(widget.shopId, a.id);
    final attached = ActivityService.attachedLabel(n.dishes, n.stockItems);
    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      iconColor: Theme.of(context).semantic.danger,
      title: 'Supprimer « ${a.name} » ?',
      body: Text(attached == null
          ? 'Aucun plat ni article de stock n\'y est rattaché.'
          : '$attached '
              '${n.dishes + n.stockItems > 1 ? 'seront détachés et passeront' : 'sera détaché et passera'} '
              'sous « Sans secteur », ventes passées comprises.'),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    await ActivityService.delete(widget.existing!.id, widget.shopId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final sem = Theme.of(context).semantic;
    return AdaptiveFormFrame(
      title: _isEdit ? 'Modifier l\'activité' : 'Nouvelle activité',
      icon: Icons.category_outlined,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
                controller: _name,
                autofocus: !_isEdit,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Nom', hintText: 'Chawarma, Glace, Bar…')),
            const SizedBox(height: 14),
            Text('Mode', style: AppTextStyles.caption),
            const SizedBox(height: 6),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'stock', label: Text('Stock')),
                ButtonSegment(value: 'recipe', label: Text('Recette')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            if (_mode == 'stock') ...[
              const SizedBox(height: 12),
              restoNumField(_seuil, 'Seuil d\'alerte (global)'),
            ],
            const SizedBox(height: 14),
            Text('Poste de service', style: AppTextStyles.caption),
            const SizedBox(height: 2),
            Text(
              'Où les articles de ce secteur sont préparés. « Auto » déduit le '
              'poste du mode : stock → bar, recette → cuisine.',
              style: AppTextStyles.captionHint,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('Auto'),
                  selected: _station == null,
                  onSelected: (_) => setState(() => _station = null),
                ),
                for (final s in ServiceStation.values)
                  ChoiceChip(
                    label: Text(s.title),
                    selected: _station == s,
                    onSelected: (_) => setState(() => _station = s),
                  ),
              ],
            ),
            if (_err != null) ...[
              const SizedBox(height: 8),
              Text(_err!,
                  style: AppTextStyles.caption.copyWith(color: sem.dangerText)),
            ],
            const SizedBox(height: 18),
            AppPrimaryButton(
                label: _isEdit ? 'Enregistrer' : 'Créer',
                icon: Icons.check_rounded,
                fullWidth: true,
                onTap: _save),
            if (_isEdit) ...[
              const SizedBox(height: 6),
              Center(
                child: TextButton.icon(
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline_rounded,
                      size: 18, color: sem.danger),
                  label: Text('Supprimer',
                      style: AppTextStyles.label.copyWith(color: sem.dangerText)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
