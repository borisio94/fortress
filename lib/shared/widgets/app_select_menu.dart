import 'package:flutter/material.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../core/theme/app_colors.dart';

// ─── Widget bouton déclencheur ────────────────────────────────────────────────

class AppSelectField extends StatelessWidget {
  final String? value;
  final String placeholder;
  final IconData? prefixIcon;
  final bool required;
  final bool hasError;
  final VoidCallback onTap;
  final bool enabled;

  const AppSelectField({
    super.key,
    this.value,
    required this.placeholder,
    this.prefixIcon,
    this.required = false,
    this.hasError = false,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFFF9FAFB)
              : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasError
                ? AppColors.error
                : const Color(0xFFE5E7EB),
            width: hasError ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          if (prefixIcon != null) ...[
            Icon(prefixIcon, size: 15,
                color: hasValue
                    ? AppColors.primary.withOpacity(0.7)
                    : const Color(0xFFAAAAAA)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              hasValue ? value! : placeholder,
              style: TextStyle(
                fontSize: 13,
                color: hasValue
                    ? const Color(0xFF1A1D2E)
                    : const Color(0xFFBBBBBB),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: hasValue
                ? const Color(0xFF6B7280)
                : const Color(0xFFBBBBBB),
          ),
        ]),
      ),
    );
  }
}

// ─── Menu popup moderne avec alternance de fond ───────────────────────────────

class AppSelectMenu {
  /// Affiche un menu popup positionné sous [anchorKey].
  ///
  /// [items] — liste des options à afficher
  /// [selected] — valeur(s) actuellement sélectionnée(s)
  /// [multi] — si true, sélection multiple avec checkboxes
  /// [onAdd] — si non null, affiche un bouton "+ Ajouter" en bas
  static Future<String?> show({
    required BuildContext context,
    required GlobalKey anchorKey,
    required List<String> items,
    String? selected,
    Set<String>? selectedSet,
    bool multi = false,
    String? addLabel,
    Future<String?> Function()? onAdd,
    Future<void> Function(String)? onDelete,
    Future<void> Function(String)? onRename,
    double minWidth = 180,
  }) async {
    final box =
    anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final pos = box.localToGlobal(Offset.zero);
    final size = box.size;

    return showMenu<String>(
      context: context,
      color: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + size.height + 4,
        pos.dx + size.width,
        0,
      ),
      constraints: BoxConstraints(
        minWidth: size.width.clamp(minWidth, 320),
        maxWidth: 320,
        maxHeight: 320,
      ),
      items: [
        // Wrapper unique qui contient toute la liste
        PopupMenuItem<String>(
          enabled: false,
          padding: EdgeInsets.zero,
          value: '__container__',
          child: _MenuContainer(
            items: items,
            selected: selected,
            selectedSet: selectedSet,
            multi: multi,
            addLabel: addLabel,
            onAdd: onAdd,
            onDelete: onDelete,
            onRename: onRename,
            onSelect: (v) => Navigator.of(context).pop(v),
          ),
        ),
      ],
    );
  }
}

// ─── Conteneur interne du menu ─────────────────────────────────────────────────

class _MenuContainer extends StatefulWidget {
  final List<String> items;
  final String? selected;
  final Set<String>? selectedSet;
  final bool multi;
  final String? addLabel;
  final Future<String?> Function()? onAdd;
  final Future<void> Function(String)? onDelete;
  final Future<void> Function(String)? onRename;
  final ValueChanged<String> onSelect;

  const _MenuContainer({
    required this.items,
    this.selected,
    this.selectedSet,
    required this.multi,
    this.addLabel,
    this.onAdd,
    this.onDelete,
    this.onRename,
    required this.onSelect,
  });

  @override
  State<_MenuContainer> createState() => _MenuContainerState();
}

class _MenuContainerState extends State<_MenuContainer> {
  late Set<String> _sel;

  @override
  void initState() {
    super.initState();
    _sel = Set.from(widget.selectedSet ?? {});
    if (widget.selected != null && widget.selected!.isNotEmpty) {
      _sel.add(widget.selected!);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.10),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
                child: Row(children: [
                  Icon(Icons.info_outline_rounded,
                      size: 15, color: AppColors.textSecondary),
                  const SizedBox(width: 8),
                  Text(context.l10n.invNoResult,
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ]),
              )
            else
              ...widget.items.asMap().entries.map((e) {
                final idx = e.key;
                final item = e.value;
                final isSelected = widget.multi
                    ? _sel.contains(item)
                    : (widget.selected == item);
                // Alternance de fond : pair = blanc, impair = très léger violet
                final bg = idx.isEven
                    ? Colors.white
                    : AppColors.primarySurface.withOpacity(0.5);
                return _MenuItem(
                  label: item,
                  isSelected: isSelected,
                  background: bg,
                  multi: widget.multi,
                  canEdit: widget.onDelete != null || widget.onRename != null,
                  onDelete: widget.onDelete != null
                      ? () async {
                    Navigator.of(context).pop('__deleted__');
                    await widget.onDelete!(item);
                  }
                      : null,
                  onRename: widget.onRename != null
                      ? () async {
                    Navigator.of(context).pop('__renamed__');
                    await widget.onRename!(item);
                  }
                      : null,
                  onTap: () {
                    if (widget.multi) {
                      setState(() {
                        if (_sel.contains(item)) _sel.remove(item);
                        else _sel.add(item);
                      });
                      widget.onSelect(item);
                    } else {
                      widget.onSelect(item);
                    }
                  },
                );
              }),

            // Bouton Ajouter
            if (widget.onAdd != null) ...[
              const Divider(height: 1, color: Color(0xFFF0F0F0)),
              InkWell(
                onTap: () async {
                  // Pop le menu d'abord
                  Navigator.of(context).pop('__add__');
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  color: Colors.white,
                  child: Row(children: [
                    Container(
                      width: 20, height: 20,
                      decoration: BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Icon(Icons.add_rounded,
                          size: 14, color: Colors.white),
                    ),
                    const SizedBox(width: 10),
                    Text(widget.addLabel ?? 'Ajouter',
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final String label;
  final bool isSelected;
  final Color background;
  final bool multi;
  final bool canEdit;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onRename;

  const _MenuItem({
    required this.label,
    required this.isSelected,
    required this.background,
    required this.multi,
    this.canEdit = false,
    this.onDelete,
    this.onRename,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        color: background,
        padding: const EdgeInsets.only(left: 14, right: 4, top: 8, bottom: 8),
        child: Row(children: [
          if (multi) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 18, height: 18,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isSelected
                      ? AppColors.primary
                      : const Color(0xFFD1D5DB),
                  width: 1.5,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check_rounded,
                  size: 11, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isSelected
                    ? FontWeight.w600 : FontWeight.w400,
                color: isSelected
                    ? AppColors.primary
                    : const Color(0xFF1A1D2E),
              ),
            ),
          ),
          if (!multi && isSelected && !canEdit)
            Icon(Icons.check_rounded,
                size: 14, color: AppColors.primary),
          // Boutons edit/delete — visibles seulement si canEdit
          if (canEdit) Row(mainAxisSize: MainAxisSize.min, children: [
            if (onRename != null)
              _IconAction(
                icon: Icons.edit_outlined,
                color: const Color(0xFF6B7280),
                onTap: onRename!,
              ),
            if (onDelete != null)
              _IconAction(
                icon: Icons.delete_outline_rounded,
                color: const Color(0xFFEF4444),
                onTap: onDelete!,
              ),
          ]),
        ]),
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _IconAction({required this.icon, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Icon(icon, size: 15, color: color),
    ),
  );
}

// ─── Widget complet champ + menu intégré ─────────────────────────────────────
// Usage : AppSelectWidget(label, items, value, onChanged, onAdd:...)

class AppSelectWidget extends StatefulWidget {
  final String label;
  final bool required;
  final List<String> items;
  final String? value;
  final ValueChanged<String> onChanged;
  final IconData? icon;
  final String? addLabel;
  final Future<String?> Function(BuildContext ctx)? onAdd;
  /// Callback appelé quand l'utilisateur supprime un item
  final Future<void> Function(String item)? onDelete;
  /// Callback appelé quand l'utilisateur renomme un item
  final Future<void> Function(String oldName, String newName)? onRename;

  const AppSelectWidget({
    super.key,
    required this.label,
    this.required = false,
    required this.items,
    this.value,
    required this.onChanged,
    this.icon,
    this.addLabel,
    this.onAdd,
    this.onDelete,
    this.onRename,
  });

  @override
  State<AppSelectWidget> createState() => _AppSelectWidgetState();
}

class _AppSelectWidgetState extends State<AppSelectWidget> {
  final _key = GlobalKey();

  Future<void> _open() async {
    final result = await AppSelectMenu.show(
      context: context,
      anchorKey: _key,
      items: widget.items,
      selected: widget.value,
      addLabel: widget.addLabel ?? (widget.onAdd != null ? 'Ajouter' : null),
      onAdd:    widget.onAdd != null ? () async => null : null,
      onDelete: widget.onDelete,
      onRename: widget.onRename != null
          ? (item) => _showRenameDialog(item) : null,
    );

    if (!mounted) return;

    if (result == '__add__' && widget.onAdd != null) {
      final newVal = await widget.onAdd!(context);
      if (newVal != null && mounted) widget.onChanged(newVal);
    } else if (result != null && result != '__container__'
        && !result.startsWith('__')) {
      widget.onChanged(result);
    }
  }

  Future<void> _showRenameDialog(String currentName) async {
    final ctrl = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (dc) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        actionsPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        title: const Text('Renommer',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        content: TextFormField(
          controller: ctrl, autofocus: true,
          style: const TextStyle(fontSize: 13, color: Color(0xFF1A1D2E)),
          decoration: InputDecoration(
            hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
            filled: true, fillColor: const Color(0xFFF9FAFB), isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dc).pop(null),
            child: const Text('Annuler',
                style: TextStyle(color: Color(0xFF6B7280))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary, foregroundColor: Colors.white,
              elevation: 0, padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 9),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isNotEmpty) Navigator.of(dc).pop(v);
            },
            child: const Text('Renommer'),
          ),
        ],
      ),
    );
    if (newName != null && newName != currentName && mounted) {
      await widget.onRename!(currentName, newName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(text: TextSpan(
          style: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w500,
              color: Color(0xFF6B7280)),
          children: [
            TextSpan(text: widget.label),
            if (widget.required)
              const TextSpan(text: ' *',
                  style: TextStyle(
                      color: Color(0xFFEF4444),
                      fontWeight: FontWeight.w700)),
          ],
        )),
        const SizedBox(height: 4),
        AppSelectField(
          key: _key,
          value: widget.value,
          placeholder: 'Sélectionner…',
          prefixIcon: widget.icon,
          onTap: _open,
        ),
      ],
    );
  }
}

// ─── Multi-select widget ──────────────────────────────────────────────────────

class AppMultiSelectWidget extends StatefulWidget {
  final String label;
  final List<String> items;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final IconData? icon;
  final String placeholder;

  const AppMultiSelectWidget({
    super.key,
    required this.label,
    required this.items,
    required this.selected,
    required this.onChanged,
    this.icon,
    this.placeholder = 'Tous',
  });

  @override
  State<AppMultiSelectWidget> createState() => _AppMultiSelectWidgetState();
}

class _AppMultiSelectWidgetState extends State<AppMultiSelectWidget> {
  final _key = GlobalKey();

  Future<void> _open() async {
    // Pour multi-select on utilise une approche différente — dialog modal
    final result = await _showMultiSelectDialog(context);
    if (result != null) widget.onChanged(result);
  }

  Future<Set<String>?> _showMultiSelectDialog(BuildContext ctx) async {
    Set<String> temp = Set.from(widget.selected);
    return showDialog<Set<String>>(
      context: ctx,
      builder: (dc) => StatefulBuilder(
        builder: (ctx2, setSt) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
          actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          title: Text(widget.label,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
          content: widget.items.isEmpty
              ? Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.l10n.invNoResult,
                style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary)),
          )
              : SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.items.length,
              itemBuilder: (_, i) {
                final item = widget.items[i];
                final sel = temp.contains(item);
                final bg = i.isEven
                    ? Colors.white
                    : AppColors.primarySurface.withOpacity(0.4);
                return InkWell(
                  onTap: () => setSt(() {
                    if (sel) temp.remove(item);
                    else temp.add(item);
                  }),
                  child: Container(
                    color: bg,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 11),
                    child: Row(children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 18, height: 18,
                        decoration: BoxDecoration(
                          color: sel
                              ? AppColors.primary
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: sel
                                ? AppColors.primary
                                : const Color(0xFFD1D5DB),
                            width: 1.5,
                          ),
                        ),
                        child: sel
                            ? const Icon(Icons.check_rounded,
                            size: 11, color: Colors.white)
                            : null,
                      ),
                      const SizedBox(width: 10),
                      Text(item,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: sel
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: sel
                                  ? AppColors.primary
                                  : const Color(0xFF1A1D2E))),
                    ]),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dc).pop(null),
              style: TextButton.styleFrom(
                  foregroundColor: AppColors.textSecondary),
              child: Text(context.l10n.invCancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dc).pop(temp),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(context.l10n.apply),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.selected.length;
    final display = count == 0
        ? widget.placeholder
        : count == 1
        ? widget.selected.first
        : '$count sélectionnés';

    return GestureDetector(
      key: _key,
      onTap: _open,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: count > 0
              ? AppColors.primarySurface : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: count > 0
                ? AppColors.primary : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 14,
                color: count > 0
                    ? AppColors.primary : const Color(0xFF6B7280)),
            const SizedBox(width: 4),
          ],
          Text(display,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: count > 0
                      ? AppColors.primary : const Color(0xFF374151))),
          if (count > 1) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10)),
              child: Text('$count',
                  style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white,
                      fontWeight: FontWeight.w700)),
            ),
          ] else ...[
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down_rounded, size: 13,
                color: count > 0
                    ? AppColors.primary : const Color(0xFF9CA3AF)),
          ],
        ]),
      ),
    );
  }
}