import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';
import 'form_sheet.dart';

// ─── Widget bouton déclencheur ────────────────────────────────────────────────

class AppSelectField extends StatelessWidget {
  final String? value;
  final String placeholder;
  final IconData? prefixIcon;
  final bool required;
  final bool hasError;
  final VoidCallback onTap;
  final bool enabled;
  final bool focused;

  const AppSelectField({
    super.key,
    this.value,
    required this.placeholder,
    this.prefixIcon,
    this.required = false,
    this.hasError = false,
    required this.onTap,
    this.enabled = true,
    this.focused = false,
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
              ? AppColors.inputFill
              : AppColors.divider,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasError
                ? AppColors.error
                : focused
                    ? AppColors.primary
                    : Theme.of(context).semantic.borderSubtle,
            width: (hasError || focused) ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          if (prefixIcon != null) ...[
            Icon(prefixIcon, size: 15,
                color: hasValue
                    ? AppColors.primary.withValues(alpha:0.7)
                    : const Color(0xFFAAAAAA)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              hasValue ? value! : placeholder,
              style: AppTextStyles.body.copyWith(
                color: hasValue
                    ? const Color(0xFF1A1D2E)
                    : AppColors.textHint,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: hasValue
                ? AppColors.textSecondary
                : AppColors.textHint,
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
    // L'Overlay sert de système de coordonnées pour `showMenu` : la
    // `RelativeRect` est interprétée comme des distances aux 4 bords de
    // l'overlay, PAS comme des positions absolues. Sans cette conversion,
    // le menu peut s'afficher loin du widget cliqué.
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    final overlaySize = overlay.size;

    return showMenu<String>(
      context: context,
      color: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy + size.height + 4,
        overlaySize.width - pos.dx - size.width,
        overlaySize.height - pos.dy - size.height,
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
  int _hi = 0;                          // index survolé au clavier
  final Map<int, GlobalKey> _keys = {}; // pour ensureVisible

  bool get _hasAdd => widget.onAdd != null;
  int  get _count  => widget.items.length + (_hasAdd ? 1 : 0);

  @override
  void initState() {
    super.initState();
    _sel = Set.from(widget.selectedSet ?? {});
    if (widget.selected != null && widget.selected!.isNotEmpty) {
      _sel.add(widget.selected!);
    }
    // Départ du surlignage = item sélectionné, sinon le 1er élément.
    final selIdx = widget.selected == null
        ? -1 : widget.items.indexOf(widget.selected!);
    _hi = selIdx >= 0 ? selIdx : 0;
  }

  GlobalKey _keyFor(int i) => _keys.putIfAbsent(i, () => GlobalKey());

  void _move(int d) {
    if (_count == 0) return;
    setState(() => _hi = (_hi + d).clamp(0, _count - 1));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[_hi]?.currentContext;
      if (ctx != null && Scrollable.maybeOf(ctx) != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.5, duration: const Duration(milliseconds: 120));
      }
    });
  }

  void _activate() {
    if (_count == 0) return;
    if (_hi < widget.items.length) {
      final item = widget.items[_hi];
      if (widget.multi) {
        setState(() {
          if (_sel.contains(item)) _sel.remove(item); else _sel.add(item);
        });
      }
      widget.onSelect(item);
    } else if (_hasAdd) {
      Navigator.of(context).pop('__add__');
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) { _move(1);  return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.arrowUp)   { _move(-1); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) { _activate(); return KeyEventResult.handled; }
    if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final addIndex = widget.items.length;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha:0.10),
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
                        style: AppTextStyles.bodySmSecondary),
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
                      ? Theme.of(context).colorScheme.surface
                      : AppColors.primarySurface.withValues(alpha:0.5);
                  return _MenuItem(
                    key: _keyFor(idx),
                    label: item,
                    isSelected: isSelected,
                    highlighted: idx == _hi,
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
              if (_hasAdd) ...[
                Divider(
                    height: 1, color: Theme.of(context).semantic.borderSubtle),
                InkWell(
                  key: _keyFor(addIndex),
                  onTap: () async {
                    Navigator.of(context).pop('__add__');
                  },
                  child: Container(
                    width: double.infinity,
                    margin: _hi == addIndex
                        ? const EdgeInsets.all(4) : EdgeInsets.zero,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: _hi == addIndex
                          ? AppColors.primarySurface.withValues(alpha:0.6)
                          : Theme.of(context).colorScheme.surface,
                      borderRadius: _hi == addIndex
                          ? BorderRadius.circular(8) : null,
                      border: _hi == addIndex
                          ? Border.all(color: AppColors.primary, width: 1.5)
                          : null,
                    ),
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
                          style: AppTextStyles.bodySm.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final String label;
  final bool isSelected;
  final bool highlighted;
  final Color background;
  final bool multi;
  final bool canEdit;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onRename;

  const _MenuItem({
    super.key,
    required this.label,
    required this.isSelected,
    this.highlighted = false,
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
        margin: highlighted ? const EdgeInsets.all(4) : EdgeInsets.zero,
        decoration: BoxDecoration(
          color: highlighted
              ? AppColors.primarySurface.withValues(alpha:0.6)
              : background,
          borderRadius: highlighted ? BorderRadius.circular(8) : null,
          border: highlighted
              ? Border.all(color: AppColors.primary, width: 1.5) : null,
        ),
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
              style: AppTextStyles.body.copyWith(
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
                color: AppColors.textSecondary,
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

  /// Active la navigation clavier : le champ devient focusable, s'ouvre
  /// automatiquement quand le focus y arrive au clavier (Entrée/→/Tab depuis
  /// le champ précédent), affiche un anneau de focus, et — après un choix —
  /// avance le focus au champ suivant. Laisser `false` ailleurs (ouverture au
  /// clic uniquement, comportement historique).
  final bool keyboardFlow;

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
    this.keyboardFlow = false,
  });

  @override
  State<AppSelectWidget> createState() => _AppSelectWidgetState();
}

class _AppSelectWidgetState extends State<AppSelectWidget> {
  final _key = GlobalKey();

  // Navigation clavier (uniquement si widget.keyboardFlow).
  FocusNode? _focus;
  bool _menuOpen = false;        // menu actuellement ouvert
  bool _menuJustClosed = false;  // évite la réouverture immédiate au retour focus
  bool _pointerDown = false;     // distingue clic (onTap gère) vs focus clavier

  @override
  void initState() {
    super.initState();
    if (widget.keyboardFlow) {
      _focus = FocusNode(debugLabel: 'select:${widget.label}');
    }
  }

  @override
  void dispose() {
    _focus?.dispose();
    super.dispose();
  }

  // Focus gagné : au clavier → ouvre le menu ; au clic → onTap s'en charge.
  void _onFocusChange(bool has) {
    if (mounted) setState(() {}); // redessine l'anneau de focus
    if (!has) { _pointerDown = false; _menuJustClosed = false; return; }
    if (_pointerDown) { _pointerDown = false; return; }       // arrivé par clic
    if (_menuJustClosed) { _menuJustClosed = false; return; } // retour post-menu
    if (_menuOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (_focus?.hasFocus ?? false) && !_menuOpen) {
        _open(byKeyboard: true);
      }
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_menuOpen || e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter ||
        e.logicalKey == LogicalKeyboardKey.arrowDown ||
        e.logicalKey == LogicalKeyboardKey.space) {
      _open(byKeyboard: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _open({bool byKeyboard = false}) async {
    if (_menuOpen) return;
    if (mounted) setState(() => _menuOpen = true);
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

    _menuOpen = false;
    _menuJustClosed = true;
    if (!mounted) return;

    var chose = false;
    if (result == '__add__' && widget.onAdd != null) {
      final newVal = await widget.onAdd!(context);
      if (newVal != null && mounted) { widget.onChanged(newVal); chose = true; }
    } else if (result != null && result != '__container__'
        && !result.startsWith('__')) {
      widget.onChanged(result);
      chose = true;
    }

    // Flux clavier UNIQUEMENT (pas au clic souris) : après un choix, avancer AU
    // champ suivant (qui s'ouvrira à son tour). nextFocus() sur _focus part de
    // CE champ → robuste même si showMenu a restauré le focus. Post-frame pour
    // passer après la restauration de focus du menu.
    if (widget.keyboardFlow && byKeyboard && mounted) {
      if (chose) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focus?.nextFocus();
        });
      } else {
        _focus?.requestFocus();
      }
    }
  }

  /// Bottom sheet de renommage. Refonte UX : remplace l'AlertDialog par
  /// un FormSheet verrouillé (X intégré, pas de tap-outside).
  Future<void> _showRenameDialog(String currentName) async {
    final ctrl = TextEditingController(text: currentName);
    final newName = await showFormSheet<String>(
      context: context,
      builder: (dc) {
        final mq = MediaQuery.of(dc);
        return Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FormSheetHeader(
                  title: 'Renommer',
                  icon: Icons.edit_rounded,
                ),
                Divider(
                    height: 1, color: Theme.of(dc).semantic.borderSubtle),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: TextFormField(
                    controller: ctrl,
                    autofocus: true,
                    style: AppTextStyles.body.copyWith(
                        color: const Color(0xFF1A1D2E)),
                    decoration: InputDecoration(
                      hintStyle: AppTextStyles.bodySm.copyWith(
                          color: AppColors.textHint),
                      filled: true,
                      fillColor: AppColors.inputFill,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 11),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: Theme.of(dc).semantic.borderSubtle)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: Theme.of(dc).semantic.borderSubtle)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                              color: AppColors.primary, width: 1.5)),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(dc).pop(null),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 44),
                          foregroundColor: AppColors.textSecondary,
                        ),
                        child: const Text('Annuler'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () {
                          final v = ctrl.text.trim();
                          if (v.isNotEmpty) Navigator.of(dc).pop(v);
                        },
                        child: const Text('Renommer'),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (newName != null && newName != currentName && mounted) {
      await widget.onRename!(currentName, newName);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget field = AppSelectField(
      key: _key,
      value: widget.value,
      placeholder: 'Sélectionner…',
      prefixIcon: widget.icon,
      focused: widget.keyboardFlow && (_focus?.hasFocus ?? false),
      onTap: () {
        _pointerDown = true; // origine clic → _onFocusChange n'ouvre pas 2×
        _open();
      },
    );
    if (widget.keyboardFlow) {
      field = Listener(
        onPointerDown: (_) => _pointerDown = true,
        child: Focus(
          focusNode: _focus,
          onFocusChange: _onFocusChange,
          onKeyEvent: _onKey,
          child: field,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label interne rendu UNIQUEMENT s'il est non vide — évite une ligne
        // fantôme quand le widget est déjà coiffé d'un label externe (_LF).
        if (widget.label.isNotEmpty) ...[
          RichText(text: TextSpan(
            style: AppTextStyles.caption.copyWith(
                color: AppColors.textSecondary),
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
        ],
        field,
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
          backgroundColor: Theme.of(dc).colorScheme.surface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          titlePadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
          actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          title: Text(widget.label,
              style: AppTextStyles.label.copyWith(
                  fontWeight: FontWeight.w700)),
          content: widget.items.isEmpty
              ? Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.l10n.invNoResult,
                style: AppTextStyles.bodySecondary),
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
                    ? Theme.of(dc).colorScheme.surface
                    : AppColors.primarySurface.withValues(alpha:0.4);
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
                          style: AppTextStyles.body.copyWith(
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
              ? AppColors.primarySurface
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: count > 0
                ? AppColors.primary
                : Theme.of(context).semantic.borderSubtle,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (widget.icon != null) ...[
            Icon(widget.icon, size: 14,
                color: count > 0
                    ? AppColors.primary : AppColors.textSecondary),
            const SizedBox(width: 4),
          ],
          Text(display,
              style: AppTextStyles.caption.copyWith(
                  color: count > 0
                      ? AppColors.primary : AppColors.onSurface)),
          if (count > 1) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(10)),
              child: Text('$count',
                  style: AppTextStyles.micro.copyWith(
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