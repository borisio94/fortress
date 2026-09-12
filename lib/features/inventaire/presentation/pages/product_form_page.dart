import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/services/pending_image_upload_service.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../core/utils/currency_formatter.dart';
import '../../../../core/utils/image_validation.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/app_text_styles.dart';
import '../../../../shared/widgets/app_scaffold.dart';
import '../../../../shared/widgets/app_section_card.dart';
import '../../../../shared/widgets/app_snack.dart';
import '../../../../shared/widgets/app_switch.dart';
import '../../../../shared/widgets/form_sheet.dart';
import '../../../../shared/widgets/app_confirm_dialog.dart';
import '../../../../core/widgets/danger_confirm_dialog.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/i18n/app_localizations.dart';
import '../../../../core/storage/local_storage_service.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/activity_log_service.dart';
import '../../../../features/inventaire/domain/entities/product.dart';
import '../../../../features/inventaire/domain/entities/stock_arrival.dart';
import '../../../../features/inventaire/domain/entities/supplier.dart';
import '../../../../features/inventaire/domain/entities/stock_location.dart';
import '../../../../core/storage/hive_boxes.dart';
import '../../../../core/services/stock_service.dart';
import '../../../../shared/widgets/app_select_menu.dart';
import '../widgets/adjust_stock_dialog.dart';

// ─── Modèles internes ─────────────────────────────────────────────────────────

class _Variant {
  /// Id de la variante PERSISTÉE (null = variante neuve, non encore sauvée).
  /// C4 — sert à ré-associer chaque ligne du formulaire à sa variante existante
  /// PAR ID (et non par position), sinon supprimer une variante du milieu
  /// décale les index et réassigne les ids des variantes suivantes → corruption
  /// d'identité (commandes ouvertes cassées, StockLevel orphelins).
  String? id;
  final TextEditingController name          = TextEditingController();
  final TextEditingController sku           = TextEditingController();
  final TextEditingController barcode       = TextEditingController();
  final TextEditingController supplier      = TextEditingController();
  final TextEditingController supplierRef   = TextEditingController();
  final TextEditingController purchasePrice = TextEditingController();
  final TextEditingController salePricePos  = TextEditingController();
  final TextEditingController salePriceWeb  = TextEditingController();
  final TextEditingController stock         = TextEditingController(text: '0');
  final TextEditingController stockAlert    = TextEditingController(text: '1');
  // Promotion par variante
  final TextEditingController promoPrice    = TextEditingController();
  DateTime? promoStart;
  DateTime? promoEnd;
  bool promoEnabled = false;
  // Poids & dimensions par variante
  final TextEditingController weight = TextEditingController();
  final TextEditingController length = TextEditingController();
  final TextEditingController width  = TextEditingController();
  final TextEditingController height = TextEditingController();
  // Images — bytes en mémoire (compatible web + mobile/desktop). Sur web,
  // image_picker retourne un blob URL non utilisable par dart:io File ;
  // les bytes lus via xFile.readAsBytes() marchent partout.
  Uint8List? imageBytes;
  String?    imageUrl;
  final List<Uint8List> secondaryImageBytes = [];
  final List<String>    secondaryImageUrls  = [];
  bool    isMain     = false;
  bool    isExpanded = true;
  /// `true` = variante jamais persistée (ajoutée dans le form). En mode édition
  /// d'un produit existant, une nouvelle variante doit pouvoir saisir son
  /// stock initial ; les variantes existantes utilisent les indicateurs +
  /// le dialogue "Corriger" à la place.
  bool    isNew      = true;
  /// Contrôle d'unicité du SKU, évalué pendant la frappe (anti-rebond).
  _SkuStatus skuStatus = _SkuStatus.empty;
  /// Nom du produit qui occupe déjà ce SKU, pour pouvoir le nommer.
  String?    skuConflictName;

  void dispose() {
    name.dispose(); sku.dispose(); barcode.dispose();
    supplier.dispose(); supplierRef.dispose();
    purchasePrice.dispose(); salePricePos.dispose();
    salePriceWeb.dispose(); stock.dispose(); stockAlert.dispose();
    promoPrice.dispose();
    weight.dispose(); length.dispose(); width.dispose(); height.dispose();
  }
}

/// État du contrôle d'unicité du SKU pendant la saisie.
enum _SkuStatus { empty, checking, available, taken }

class _Expense {
  final TextEditingController description = TextEditingController();
  final TextEditingController amount      = TextEditingController(text: '0');
  void dispose() { description.dispose(); amount.dispose(); }
}

/// Erreur de validation rattachée à l'étape qui la porte (0-indexée), pour
/// pouvoir y ramener l'utilisateur au lieu d'échouer depuis une autre étape.
class _StepError {
  final int    step;
  final String message;
  const _StepError(this.step, this.message);
}

// ─── Page ─────────────────────────────────────────────────────────────────────

/// Paramètre optionnel transporté via `go_router.extra` pour ouvrir le formulaire
/// sur une variante précise ou pour pré-ajouter une nouvelle variante.
///
/// - [focusVariantId] : ouvre l'étape 2 avec cette variante seule dépliée.
/// - [addNewVariant]  : ouvre l'étape 2 avec une nouvelle variante vide
///   déjà ajoutée et dépliée (les variantes existantes sont repliées).
///
/// Les autres callers peuvent continuer à passer juste un `Product`.
class ProductFormExtra {
  final Product product;
  final String? focusVariantId;
  final bool addNewVariant;
  const ProductFormExtra({
    required this.product,
    this.focusVariantId,
    this.addNewVariant = false,
  });
}

class ProductFormPage extends StatefulWidget {
  final String shopId;
  final Object? extra;
  const ProductFormPage({super.key, required this.shopId, this.extra});
  @override State<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<ProductFormPage> {
  final _pageCtrl = PageController();
  int  _step      = 0;
  static const _totalSteps = 3;

  final _keys = List.generate(3, (_) => GlobalKey<FormState>());

  // ── Listes dynamiques ────────────────────────────────────────────
  List<String> _categories = [];
  List<String> _brands     = [];
  List<String> _units      = [];
  List<Supplier> _suppliers = [];

  /// Produit en cours d'édition. `widget.extra` peut être soit un `Product`
  /// (historique), soit un `ProductFormExtra` (nouveau, avec focusVariantId).
  /// `null` en mode création.
  Product? get _editingProduct {
    final e = widget.extra;
    if (e is Product) return e;
    if (e is ProductFormExtra) return e.product;
    return null;
  }

  /// `true` en création (aucun produit transmis). Sert à n'exiger marque et
  /// catégorie qu'à ce moment-là : un produit déjà au catalogue peut ne pas
  /// en avoir, et on ne veut pas rendre sa modification impossible.
  bool get _isCreating => _editingProduct == null;

  /// Fournisseur choisi via le picker — permet d'afficher les infos
  /// (téléphone, email, adresse) en dessous. `null` si saisie manuelle.
  Supplier? _selectedSupplier;

  // ── Étape 1 ───────────────────────────────────────────────────────
  final _nameCtrl      = TextEditingController();
  final _brandCtrl     = TextEditingController();
  final _descCtrl      = TextEditingController();
  final _notesCtrl     = TextEditingController();
  final _supplierCtrl  = TextEditingController();
  final _supplierRefCtrl = TextEditingController();
  String _category = '';
  String _brand    = '';
  String _unit     = '';

  // ── Étape 2 ───────────────────────────────────────────────────────
  final List<_Variant> _variants = [];
  final List<_Expense> _expenses = [];
  final _taxRateCtrl = TextEditingController(text: '0');

  // ── Étape 3 ───────────────────────────────────────────────────────
  bool  _isActive     = true;
  // Visibilité web activée par défaut à la CRÉATION (en édition, écrasée par
  // la valeur du produit dans _fillFromProduct, gardé après `if (p == null)`).
  bool  _isVisibleWeb = true;
  // Suivi de stock activé par défaut (hotfix_138) : le comportement
  // historique reste la norme, on ne le désactive que volontairement.
  bool  _trackStock   = true;
  int   _rating       = 0;

  // ── Calculs ───────────────────────────────────────────────────────
  double get _totalExpenses =>
      _expenses.fold(0.0, (s, e) => s + (double.tryParse(e.amount.text) ?? 0));

  int get _totalStock =>
      _variants.fold(0, (s, v) => s + (int.tryParse(v.stock.text) ?? 0));

  double get _expensePerUnit =>
      _totalStock > 0 ? _totalExpenses / _totalStock : 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCategories();
      _prefillIfEdit();
    });
  }

  void _loadCategories() {
    setState(() {
      _categories = LocalStorageService.getCategories(widget.shopId);
      _brands     = LocalStorageService.getBrands(widget.shopId);
      _units      = LocalStorageService.getUnits(widget.shopId);
      _suppliers  = _loadSuppliers();
    });
    if (widget.extra == null && _variants.isEmpty) {
      final base = _Variant()..isMain = true..isExpanded = true;
      setState(() => _variants.add(base));
    }
    // En création, `_prefillIfEdit` ne pose pas d'empreinte : on la capture
    // ici, formulaire vide, pour que la moindre saisie soit détectée.
    _initialSignature ??= _formSignature();
  }

  /// Charge les fournisseurs actifs de la boutique depuis Hive.
  List<Supplier> _loadSuppliers() => HiveBoxes.suppliersBox.values
      .map((m) => Supplier.fromMap(Map<String, dynamic>.from(m)))
      .where((s) => s.shopId == widget.shopId && s.isActive)
      .toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Tente de matcher le fournisseur du produit (saisi en texte) à un
  /// fournisseur existant par nom, pour pré-afficher les infos.
  Supplier? _matchSupplierByName(String name) {
    final n = name.trim().toLowerCase();
    if (n.isEmpty) return null;
    for (final s in _suppliers) {
      if (s.name.trim().toLowerCase() == n) return s;
    }
    return null;
  }

  void _prefillIfEdit() {
    // L'extra peut être soit un Product (cas historique), soit un
    // ProductFormExtra avec un variantId à cibler (focus).
    final raw = widget.extra;
    Product? p;
    String? focusVariantId;
    bool addNewVariant = false;
    if (raw is Product) {
      p = raw;
    } else if (raw is ProductFormExtra) {
      p = raw.product;
      focusVariantId = raw.focusVariantId;
      addNewVariant = raw.addNewVariant;
    }
    if (p == null) return;
    _nameCtrl.text    = p.name;
    _brandCtrl.text   = p.brand ?? '';
    if (p.brand != null && p.brand!.isNotEmpty) _brand = p.brand!;
    _descCtrl.text    = p.description ?? '';
    _taxRateCtrl.text = p.taxRate.toString();
    // Fournisseur global — lire depuis la première variante
    final firstVariant = p.variants.isNotEmpty ? p.variants.first : null;
    _supplierCtrl.text    = firstVariant?.supplier ?? '';
    _supplierRefCtrl.text = firstVariant?.supplierRef ?? '';
    // Ré-associer le fournisseur si un fournisseur enregistré correspond
    _selectedSupplier = _matchSupplierByName(_supplierCtrl.text);
    _isActive         = p.isActive;
    _isVisibleWeb     = p.isVisibleWeb;
    _trackStock       = p.trackStock;
    _rating           = p.rating;

    final cat = p.categoryId ?? 'Autre';
    if (!_categories.contains(cat)) _categories.add(cat);

    for (final v in _variants) v.dispose();
    _variants.clear();
    if (p.variants.isNotEmpty) {
      // Si aucune variante ciblée n'existe (ou sans id), on replie sur la 1re.
      final hasFocus = focusVariantId != null &&
          p.variants.any((v) => v.id == focusVariantId);
      for (int i = 0; i < p.variants.length; i++) {
        final v  = p.variants[i];
        final nv = _Variant();
        nv.id                 = v.id; // C4 — conserver l'id pour matcher au save
        nv.name.text          = v.name;
        nv.sku.text           = v.sku ?? '';
        nv.barcode.text       = v.barcode ?? '';
        nv.supplier.text      = v.supplier ?? '';
        nv.supplierRef.text   = v.supplierRef ?? '';
        nv.purchasePrice.text = v.priceBuy > 0 ? v.priceBuy.toString() : '';
        nv.salePricePos.text  = v.priceSellPos > 0 ? v.priceSellPos.toString() : '';
        nv.salePriceWeb.text  = v.priceSellWeb > 0 ? v.priceSellWeb.toString() : '';
        nv.stock.text         = v.stockQty.toString();
        nv.stockAlert.text    = v.stockMinAlert.toString();
        nv.imageUrl              = v.imageUrl;
        nv.secondaryImageUrls.addAll(v.secondaryImageUrls);
        nv.isMain                = v.isMain;
        nv.isNew                 = false; // variante persistée (non neuve)
        // Focus variant → seule elle dépliée. Sinon : 1re dépliée, autres repliées.
        nv.isExpanded            = hasFocus ? v.id == focusVariantId : i == 0;
        nv.promoEnabled          = v.promoEnabled;
        if (v.promoPrice != null) nv.promoPrice.text = v.promoPrice!.toStringAsFixed(0);
        nv.promoStart            = v.promoStart;
        nv.promoEnd              = v.promoEnd;
        _variants.add(nv);
      }
      // Si focus actif, ouvrir directement l'étape 2 (Variantes).
      if (hasFocus) {
        _step = 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageCtrl.hasClients) {
            _pageCtrl.jumpToPage(1);
          }
        });
      }
      // Si ajout d'une nouvelle variante : replier les existantes, ajouter
      // une variante vide dépliée, et sauter à l'étape 2.
      if (addNewVariant) {
        for (final existing in _variants) {
          existing.isExpanded = false;
        }
        _variants.add(_Variant()..isExpanded = true..isNew = true);
        _step = 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pageCtrl.hasClients) {
            _pageCtrl.jumpToPage(1);
          }
        });
      }
    } else {
      final base = _Variant();
      base.name.text          = p.name;
      base.sku.text           = p.sku ?? '';
      base.barcode.text       = p.barcode ?? '';
      base.purchasePrice.text = p.priceBuy > 0 ? p.priceBuy.toString() : '';
      base.salePricePos.text  = p.priceSellPos > 0 ? p.priceSellPos.toString() : '';
      base.salePriceWeb.text  = p.priceSellWeb > 0 ? p.priceSellWeb.toString() : '';
      base.stock.text         = p.stockQty.toString();
      base.imageUrl           = p.imageUrl;
      base.isMain             = true;
      base.isExpanded         = true;
      base.isNew              = false; // variante reconstruite depuis l'ancien format
      // Pas d'images secondaires dans ce cas (ancien format)
      _variants.add(base);
    }

    for (final e in _expenses) e.dispose();
    _expenses.clear();
    for (final expMap in p.expenses) {
      final ex = _Expense();
      ex.description.text = expMap['description'] as String? ?? '';
      ex.amount.text = (expMap['amount'] as num?)?.toStringAsFixed(0) ?? '0';
      ex.amount.addListener(() => setState(() {}));
      _expenses.add(ex);
    }
    setState(() => _category = cat);
    _initialSignature = _formSignature();
  }

  @override
  void dispose() {
    _skuDebounce?.cancel();
    for (final c in [_nameCtrl, _brandCtrl, _descCtrl, _notesCtrl,
      _taxRateCtrl, _pageCtrl]) c.dispose();
    for (final v in _variants) v.dispose();
    for (final e in _expenses) e.dispose();
    super.dispose();
  }

  void _showError(String message) => AppSnack.error(context, message);

  // ── Navigation ────────────────────────────────────────────────────
  void _goTo(int step) {
    setState(() => _step = step);
    _pageCtrl.animateToPage(step,
        duration: const Duration(milliseconds: 280), curve: Curves.easeInOut);
  }

  void _next() {
    if (_keys[_step].currentState?.validate() == false) {
      _showValidationError(); return;
    }
    if (_step < _totalSteps - 1) _goTo(_step + 1);
  }

  void _prev() { if (_step > 0) _goTo(_step - 1); }

  void _showValidationError() =>
      AppSnack.warning(context, context.l10n.prodStepValidError);

  bool _isSaving = false;

  /// Anti-rebond du contrôle de SKU. Un seul suffit : on ne saisit que dans
  /// un champ à la fois.
  Timer? _skuDebounce;

  /// Empreinte du formulaire juste après le pré-remplissage. Sert à savoir
  /// s'il y a vraiment quelque chose à perdre : sans elle, on ouvrirait le
  /// dialogue de sortie même quand l'utilisateur n'a rien touché.
  String? _initialSignature;

  /// Id du brouillon déjà écrit, pour que deux sorties successives mettent à
  /// jour la MÊME fiche au lieu d'en empiler une par sortie.
  String? _draftId;

  void _submit() {
    if (_isSaving) return;
    // Contrôle de TOUTES les étapes, pas seulement celle affichée. La barre
    // d'étapes permet d'atterrir directement sur l'étape 3 : sans ça, on
    // enregistre un produit dont le SKU ou le prix d'achat est vide, et rien
    // ne le signale avant l'écriture — ou jamais.
    final err = _validateAllSteps();
    if (err != null) {
      if (_step != err.step) _goTo(err.step);
      AppSnack.error(context, err.message);
      return;
    }
    if (_keys[_step].currentState?.validate() == false) {
      _showValidationError(); return;
    }
    _saveProduct();
  }

  /// Renvoie la première erreur trouvée avec son étape, `null` si tout est bon.
  ///
  /// Reproduit exactement les règles des validateurs de champ déjà en place —
  /// on ne durcit rien, on les rend seulement atteignables depuis n'importe
  /// quelle étape. Seules marque et catégorie sont nouvelles, et uniquement
  /// à la création (cf. [_isCreating]).
  _StepError? _validateAllSteps() {
    // ── Étape 1 ────────────────────────────────────────────────────────
    if (_nameCtrl.text.trim().isEmpty) {
      return const _StepError(0, 'Le nom du produit est requis');
    }
    if (_isCreating) {
      if (_category.trim().isEmpty) {
        return const _StepError(0, 'La catégorie est requise');
      }
      if (_brand.trim().isEmpty) {
        return const _StepError(0, 'La marque est requise');
      }
    }

    // ── Étape 2 ────────────────────────────────────────────────────────
    final seenSku = <String>{};
    for (final v in _variants) {
      if (v.name.text.trim().isEmpty) {
        return const _StepError(1, 'Chaque variante doit porter un nom');
      }
      final label = '« ${v.name.text.trim()} »';
      if (v.sku.text.trim().isEmpty) {
        return _StepError(1, 'Le SKU est requis pour $label');
      }
      if (!seenSku.add(v.sku.text.trim().toLowerCase())) {
        return _StepError(1,
            'Le SKU « ${v.sku.text.trim()} » est utilisé par deux variantes');
      }
      if (v.skuStatus == _SkuStatus.taken) {
        return _StepError(1, v.skuConflictName == null
            ? 'Le SKU de $label est déjà utilisé par un autre produit'
            : 'Le SKU de $label est déjà pris par « ${v.skuConflictName} »');
      }
      if (v.purchasePrice.text.trim().isEmpty) {
        return _StepError(1, 'Le prix d\'achat est requis pour $label');
      }
      // Les champs de stock n'existent pas en mode « sur commande », et le
      // stock d'une variante déjà enregistrée passe par « Corriger ».
      if (_trackStock) {
        if (v.stockAlert.text.trim().isEmpty) {
          return _StepError(1, 'L\'alerte de stock est requise pour $label');
        }
        if (v.isNew && v.stock.text.trim().isEmpty) {
          return _StepError(1, 'Le stock initial est requis pour $label');
        }
      }
    }
    return null;
  }

  /// Texte du bandeau d'avertissement affiché en MODIFICATION quand marque
  /// ou catégorie manque — non bloquant (cf. [_validateAllSteps]).
  String _missingTaxonomyWarning() {
    final missing = <String>[
      if (_category.trim().isEmpty) 'de catégorie',
      if (_brand.trim().isEmpty)    'de marque',
    ];
    final list = missing.join(' ni ');
    return 'Ce produit n\'a pas $list. Vous pouvez l\'enregistrer ainsi, '
        'mais il sera absent des filtres du catalogue en ligne et plus '
        'difficile à retrouver en caisse.';
  }

  /// Suppression d'une variante — jamais immédiate.
  ///
  /// Avant, la croix retirait la variante sur-le-champ, y compris une variante
  /// DÉJÀ ENREGISTRÉE avec du stock : la ligne disparaissait, et
  /// l'enregistrement la retirait définitivement du produit (niveaux de stock
  /// orphelins, lignes de commande pointant dans le vide).
  Future<void> _confirmRemoveVariant(_Variant v) async {
    final named = v.name.text.trim();
    final title = named.isEmpty ? 'cette variante' : '« $named »';
    final saved = !v.isNew;
    final stock = int.tryParse(v.stock.text.trim()) ?? 0;

    final String body;
    if (saved && stock > 0) {
      body = 'Cette variante est enregistrée et il lui reste $stock '
          'unité${stock > 1 ? 's' : ''} en stock. La supprimer retire ce stock '
          'du produit. Irréversible une fois le produit enregistré.';
    } else if (saved) {
      body = 'Cette variante est déjà enregistrée. Irréversible une fois le '
          'produit enregistré.';
    } else {
      body = 'Cette variante n\'a pas encore été enregistrée.';
    }

    final ok = await AppConfirmDialog.show(
      context: context,
      icon: Icons.delete_outline_rounded,
      title: 'Supprimer $title ?',
      body: Text(body, style: TextStyle(fontSize: 12, height: 1.45,
          color: AppColors.textSecondary)),
      cancelLabel: 'Annuler',
      confirmLabel: 'Supprimer',
      onConfirm: () {},
    );
    if (ok != true || !mounted) return;
    // Retrait PAR RÉFÉRENCE, pas par index : entre l'ouverture de la feuille
    // et la confirmation, la liste a pu bouger.
    setState(() { if (_variants.remove(v)) v.dispose(); });
  }

  /// Concatène tout ce qui est saisissable. Volontairement grossier : on ne
  /// cherche pas à dire QUOI a changé, seulement SI quelque chose a changé.
  String _formSignature() => [
    _nameCtrl.text, _brandCtrl.text, _descCtrl.text, _notesCtrl.text,
    _supplierCtrl.text, _supplierRefCtrl.text, _taxRateCtrl.text,
    _category, _brand, _unit,
    '$_isActive|$_isVisibleWeb|$_trackStock|$_rating',
    for (final v in _variants)
      '${v.name.text}|${v.sku.text}|${v.barcode.text}|'
      '${v.purchasePrice.text}|${v.salePricePos.text}|${v.salePriceWeb.text}|'
      '${v.stock.text}|${v.stockAlert.text}|${v.promoEnabled}|'
      '${v.promoPrice.text}|${v.imageBytes?.length ?? 0}|'
      '${v.secondaryImageBytes.length}',
    for (final e in _expenses) '${e.description.text}|${e.amount.text}',
  ].join('¦');

  bool _hasUnsavedChanges() =>
      _initialSignature != null && _formSignature() != _initialSignature;

  /// Complétude de la fiche, de 0 à 1. Pondère ce qui compte réellement
  /// pour vendre : sans prix ni stock un produit n'est pas exploitable,
  /// alors qu'une catégorie manquante ne gêne que les filtres.
  double get _profileCompletion {
    final v = _variants.isEmpty ? null : _variants.first;
    var score = 0.0;
    if (_nameCtrl.text.trim().isNotEmpty)               score += 0.20;
    if (_category.trim().isNotEmpty)                    score += 0.10;
    if ((double.tryParse(v?.purchasePrice.text ?? '') ?? 0) > 0) score += 0.20;
    if ((double.tryParse(v?.salePricePos.text ?? '')  ?? 0) > 0) score += 0.20;
    // Un article sur commande n'a pas de stock à renseigner : on ne lui
    // reproche pas une case qu'on lui retire.
    if (!_trackStock || (int.tryParse(v?.stock.text ?? '') ?? 0) > 0) {
      score += 0.15;
    }
    if (_variants.any((x) => x.imageBytes != null || x.imageUrl != null)) {
      score += 0.15;
    }
    return score.clamp(0.0, 1.0);
  }

  /// Retourne `true` si la page peut se fermer.
  ///
  /// « Garder le brouillon » n'est proposé QU'EN CRÉATION : appliqué à un
  /// produit déjà publié, l'enregistrement en brouillon le dépublierait
  /// (`isActive: false` + statut brouillon) — un effet de bord inacceptable
  /// sur une fiche en ligne.
  Future<bool> _confirmExit() async {
    if (!_hasUnsavedChanges()) return true;
    final canDraft = _isCreating;
    final choice = await showFormSheet<String>(
      context: context,
      builder: (dc) => SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const FormSheetHeader(
              title: 'Quitter sans enregistrer ?',
              icon: Icons.help_outline_rounded),
          Divider(height: 1, color: Theme.of(dc).semantic.borderSubtle),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(
              canDraft
                  ? 'Votre saisie n\'est pas enregistrée. Vous pouvez la '
                    'garder en brouillon et la reprendre plus tard : le '
                    'produit ne sera ni vendable ni visible en ligne.'
                  : 'Vos modifications ne sont pas enregistrées et seront '
                    'perdues.',
              style: TextStyle(fontSize: 12, height: 1.45,
                  color: AppColors.textSecondary)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(children: [
              SizedBox(width: double.infinity, height: 46,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(dc).pop('stay'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white, elevation: 0,
                    minimumSize: const Size(0, 46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10))),
                  child: const Text('Continuer à modifier'))),
              if (canDraft) ...[
                const SizedBox(height: 8),
                SizedBox(width: double.infinity, height: 46,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.of(dc).pop('draft'),
                    icon: const Icon(Icons.bookmark_outline_rounded, size: 18),
                    label: const Text('Garder le brouillon'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46)))),
              ],
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, height: 46,
                child: TextButton(
                  onPressed: () => Navigator.of(dc).pop('leave'),
                  style: TextButton.styleFrom(
                      foregroundColor: AppColors.error,
                      minimumSize: const Size(0, 46)),
                  child: const Text('Quitter sans enregistrer'))),
            ]),
          ),
        ]),
      ),
    );
    if (choice == 'draft') return _saveDraft();
    return choice == 'leave';
  }

  /// Écrit la saisie en cours comme brouillon. Chemin de sauvegarde normal
  /// (`AppDatabase.saveProduct`), jamais `_doSaveProduct` — qui reste
  /// réservé à l'enregistrement réel et n'est pas touché.
  ///
  /// `skipValidation` : un brouillon est par nature incomplet, son SKU peut
  /// être vide ou déjà pris. Le refuser reviendrait à perdre la saisie,
  /// c'est-à-dire exactement ce qu'on cherche à éviter. Les contrôles
  /// d'unicité s'appliqueront à l'enregistrement définitif.
  ///
  /// Limite assumée : les images choisies mais pas encore envoyées ne sont
  /// PAS mises en file pour un brouillon — la file est plafonnée à 50
  /// entrées et sert les produits réels. Les images déjà en ligne restent.
  Future<bool> _saveDraft() async {
    try {
      final now = DateTime.now();
      final id  = _draftId ?? 'prod_${now.microsecondsSinceEpoch}';
      final name = _nameCtrl.text.trim().isEmpty
          ? 'Brouillon du ${now.day}/${now.month}'
          : _nameCtrl.text.trim();

      final variants = <ProductVariant>[];
      for (int i = 0; i < _variants.length; i++) {
        final v = _variants[i];
        final qty = int.tryParse(v.stock.text.trim()) ?? 0;
        variants.add(ProductVariant(
          id:   v.id ?? 'var_${now.microsecondsSinceEpoch}_$i',
          name: v.name.text.trim().isEmpty ? 'Base' : v.name.text.trim(),
          sku:  v.sku.text.trim().isEmpty ? null : v.sku.text.trim(),
          barcode: v.barcode.text.trim().isEmpty
              ? null : v.barcode.text.trim(),
          priceBuy:       double.tryParse(v.purchasePrice.text.trim()) ?? 0,
          priceSellPos:   double.tryParse(v.salePricePos.text.trim())  ?? 0,
          priceSellWeb:   double.tryParse(v.salePriceWeb.text.trim())  ?? 0,
          stockAvailable: qty,
          stockPhysical:  qty,
          stockMinAlert:  int.tryParse(v.stockAlert.text.trim()) ?? 1,
          imageUrl:       v.imageUrl,
          isMain:         i == 0,
        ));
      }

      final draft = Product(
        id:          id,
        storeId:     widget.shopId,
        name:        name,
        categoryId:  _category.isEmpty ? null : _category,
        brand:       _brand.isEmpty ? null : _brand,
        description: _descCtrl.text.trim().isEmpty
            ? null : _descCtrl.text.trim(),
        status:      ProductStatus.draft,
        // Un brouillon n'est ni vendable ni publiable : ces deux drapeaux
        // sont ce que la caisse et les RPC publiques regardent réellement.
        isActive:     false,
        isVisibleWeb: false,
        trackStock:   _trackStock,
        variants:     variants,
        createdAt:    now,
        draftExpiresAt: now.add(const Duration(days: 7)),
      );

      await AppDatabase.saveProduct(draft,
          skipValidation: true, skipStockLog: true);
      _draftId = id;
      if (mounted) AppSnack.info(context, 'Brouillon conservé 7 jours');
      return true;
    } catch (e) {
      if (mounted) AppSnack.error(context, 'Brouillon non enregistré : $e');
      return false;
    }
  }

  /// Contrôle d'unicité du SKU pendant la frappe, avec anti-rebond de 800 ms :
  /// sans lui, on parcourait le catalogue à chaque caractère. Le conflit ne se
  /// révélait auparavant qu'à l'enregistrement, après deux minutes de saisie.
  void _onSkuChanged(String value, _Variant v) {
    _skuDebounce?.cancel();
    final sku = value.trim();
    if (sku.isEmpty) {
      setState(() {
        v.skuStatus       = _SkuStatus.empty;
        v.skuConflictName = null;
      });
      return;
    }
    setState(() => v.skuStatus = _SkuStatus.checking);
    _skuDebounce = Timer(const Duration(milliseconds: 800),
        () => _checkSkuAvailability(sku, v));
  }

  Future<void> _checkSkuAvailability(String sku, _Variant v) async {
    final existing = await AppDatabase.findProductBySku(widget.shopId, sku);
    if (!mounted) return;
    // Retrouver ce SKU sur le produit qu'on est justement en train de
    // modifier n'est pas un conflit.
    final taken = existing != null && existing.id != _editingProduct?.id;
    setState(() {
      v.skuStatus       = taken ? _SkuStatus.taken : _SkuStatus.available;
      v.skuConflictName = taken ? existing.name : null;
    });
  }

  Future<void> _saveProduct() async {
    setState(() => _isSaving = true);
    try {
      await _doSaveProduct();
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _doSaveProduct() async {
    if (_variants.isNotEmpty && !_variants.any((v) => v.isMain)) {
      _variants[0].isMain = true;
    }
    final baseTs = DateTime.now().microsecondsSinceEpoch;
    final List<ProductVariant> variants = [];
    // Indices des variantes NOUVELLES (création / variante ajoutée à un
    // produit existant) avec stock initial > 0. Après save, on baseline
    // `stock_movements` pour chacune → l'audit de réconciliation ne
    // détectera pas de faux drift.
    final List<int> newVariantsToBaseline = [];

    // Relire le produit frais depuis Hive (widget.extra est un snapshot du
    // moment où le form a été ouvert ; entre-temps le stock a pu être modifié
    // par des arrivées/incidents). On veut préserver ces mises à jour.
    final extraId = _editingProduct?.id;
    final freshProduct = extraId != null
        ? AppDatabase.getProductsForShop(widget.shopId)
            .where((p) => p.id == extraId).firstOrNull
        : null;

    for (int i = 0; i < _variants.length; i++) {
      final v = _variants[i];
      // C4 — retrouver la variante existante PAR ID (jamais par index).
      ProductVariant? existingVariant;
      if (freshProduct != null && v.id != null) {
        for (final e in freshProduct.variants) {
          if (e.id == v.id) { existingVariant = e; break; }
        }
      }

      // Image URL : utiliser ce qui existe déjà (distant). Si l'utilisateur
      // vient de choisir une nouvelle image (bytes en mémoire), on laisse
      // imageUrl null — l'upload background la définira après navigation.
      String? varImageUrl;
      if (v.imageBytes != null) {
        if (existingVariant?.imageUrl != null &&
            StorageService.isRemoteUrl(existingVariant!.imageUrl)) {
          StorageService.deleteImage(existingVariant.imageUrl!);
        }
      } else if (existingVariant?.imageUrl != null) {
        varImageUrl = existingVariant!.imageUrl;
      } else if (v.imageUrl != null && v.imageUrl!.isNotEmpty) {
        varImageUrl = v.imageUrl;
      }

      // Images secondaires — garder uniquement les URLs distantes ; les
      // bytes locaux seront uploadés en background et ajoutés à la liste.
      final List<String> savedSecondaryUrls = [
        ...v.secondaryImageUrls.where(StorageService.isRemoteUrl),
      ];

      // En édition d'une variante déjà persistée : on préserve les compteurs
      // de stock — la modification se fait via le bouton "Corriger" (qui
      // appelle StockService.adjustment, log un mouvement et propage proprement
      // variant + StockLevel boutique). Le champ "Stock initial" du form n'est
      // affiché qu'en création (cf. plus bas, `if (productId == null || variant.isNew)`).
      final isEditing = !v.isNew && existingVariant != null;
      final formStock = int.tryParse(v.stock.text) ?? 0;

      variants.add(ProductVariant(
        // C4 — variante existante → garder SON id ; neuve (v.id null) → générer.
        id:                   v.id ?? 'var_${baseTs}_$i',
        name:                 v.name.text.trim().isEmpty ? 'Base' : v.name.text.trim(),
        sku:                  v.sku.text.trim().isEmpty ? null : v.sku.text.trim(),
        barcode:              v.barcode.text.trim().isEmpty ? null : v.barcode.text.trim(),
        supplier:             _supplierCtrl.text.trim().isEmpty ? null : _supplierCtrl.text.trim(),
        supplierRef:          _supplierRefCtrl.text.trim().isEmpty ? null : _supplierRefCtrl.text.trim(),
        priceBuy:             double.tryParse(v.purchasePrice.text) ?? 0,
        priceSellPos:         double.tryParse(v.salePricePos.text) ?? 0,
        priceSellWeb:         double.tryParse(v.salePriceWeb.text) ?? 0,
        stockAvailable:       isEditing ? existingVariant.stockAvailable : formStock,
        stockPhysical:        isEditing ? existingVariant.stockPhysical  : formStock,
        stockBlocked:         isEditing ? existingVariant.stockBlocked   : 0,
        stockOrdered:         isEditing ? existingVariant.stockOrdered   : 0,
        stockMinAlert:        int.tryParse(v.stockAlert.text) ?? 1,
        imageUrl:             varImageUrl,
        secondaryImageUrls:   savedSecondaryUrls,
        isMain:               v.isMain,
        promoEnabled:         v.promoEnabled,
        promoPrice:           double.tryParse(v.promoPrice.text),
        promoStart:           v.promoStart,
        promoEnd:             v.promoEnd,
      ));

      if (!isEditing && formStock > 0) {
        newVariantsToBaseline.add(i);
      }
    }

    final expensesList = _expenses.map((e) => {
      'description': e.description.text.trim(),
      'amount': double.tryParse(e.amount.text) ?? 0,
    }).toList();

    final baseVariant = variants.isNotEmpty ? variants[0] : null;
    final mainVariant = variants.where((v) => v.isMain).firstOrNull ?? baseVariant;
    final existingId  = _editingProduct?.id;

    final product = Product(
      id:            existingId ?? 'prod_${baseTs}',
      storeId:       widget.shopId,
      categoryId:    _category.isEmpty ? null : _category,
      brand:         _brand.isEmpty ? null : _brand,
      name:          _nameCtrl.text.trim(),
      description:   _descCtrl.text.trim().isEmpty ? null : _descCtrl.text.trim(),
      barcode:       baseVariant?.barcode,
      sku:           baseVariant?.sku,
      priceBuy:      baseVariant?.priceBuy ?? 0,
      customsFee:    0,
      priceSellPos:  baseVariant?.priceSellPos ?? 0,
      priceSellWeb:  baseVariant?.priceSellWeb ?? 0,
      taxRate:       double.tryParse(_taxRateCtrl.text) ?? 0,
      stockQty:      baseVariant?.stockQty ?? 0,
      stockMinAlert: baseVariant?.stockMinAlert ?? 1,
      isActive:      _isActive,
      isVisibleWeb:  _isVisibleWeb,
      trackStock:    _trackStock,
      imageUrl:      mainVariant?.imageUrl,
      rating:        _rating,
      variants:      variants,
      expenses:      expensesList,
      createdAt:     _editingProduct?.createdAt ?? DateTime.now(),
    );

    // 1. Hive immédiat + Supabase background.
    //    `forceStockLevelSync` : édition explicite par l'utilisateur, sa
    //    valeur de stock doit écraser le StockLevel boutique même si un
    //    transfert/vente récent a marqué l'écho local (sinon la "vue
    //    boutique" affiche encore l'ancienne valeur, alors que la liste
    //    des variantes affiche la nouvelle → divergence visuelle).
    final isEdit = existingId != null;
    try {
      await AppDatabase.saveProduct(product, forceStockLevelSync: true);
    } catch (e) {
      if (mounted) {
        AppSnack.error(context, e.toString().replaceAll('Exception: ', ''));
      }
      return;
    }

    // 1bis-pré. Baseline stock_movements pour les variantes nouvellement
    // créées — sans ça, l'audit réconciliation détectera un faux drift
    // ("attendu 0, actuel N") parce que ProductFormPage écrit
    // stockAvailable=N direct sans passer par StockService.arrival.
    // `logInitialBaseline` log SEUL (pas d'incrément) → idempotent et safe.
    for (final idx in newVariantsToBaseline) {
      if (idx >= variants.length) continue;
      final vid = variants[idx].id;
      if (vid == null || vid.isEmpty) continue;
      await StockService.logInitialBaseline(
        shopId:         widget.shopId,
        productId:      product.id ?? '',
        variantId:      vid,
        stockAvailable: variants[idx].stockAvailable,
      );
    }

    // 1bis. Journal d'activité (création ou édition).
    await ActivityLogService.log(
      action:      isEdit ? 'product_updated' : 'product_created',
      targetType:  'product',
      targetId:    product.id,
      targetLabel: product.name,
      shopId:      product.storeId,
      details: {
        'price': product.priceSellPos,
        'stock': product.stockQty,
        if (_category.isNotEmpty) 'category': _category,
        if (_brand.isNotEmpty)    'brand':    _brand,
      },
    );

    // 2. Arrivées déjà "consommées" → elles ont incrémenté le stock pendant
    //    la session. On nettoie pour que la section soit vide à la prochaine
    //    ouverture. Les incidents éventuels restent visibles dans leur page
    //    dédiée et gèrent leur propre cycle.
    final prodId = product.id;
    if (prodId != null) {
      final keys = HiveBoxes.stockArrivalsBox.keys.where((k) {
        final m = HiveBoxes.stockArrivalsBox.get(k);
        return m is Map && m['product_id'] == prodId;
      }).toList();
      for (final k in keys) {
        await HiveBoxes.stockArrivalsBox.delete(k);
      }
    }

    // 3. Catégorie en arrière-plan (non bloquant)
    if (_category.isNotEmpty) AppDatabase.saveCategory(widget.shopId, _category);

    // 3. Upload images en arrière-plan APRÈS navigation
    _uploadImagesInBackground(product, baseTs);

    if (!mounted) return;
    AppSnack.success(context, '${product.name} enregistré !');
    context.pop();
  }


  /// Persiste les bytes PNG des nouvelles images dans la file Hive
  /// `pendingImageUploadsBox`, puis tente un flush immédiat. La file
  /// survit à un refresh / fermeture d'onglet — sur 3G, l'utilisateur
  /// peut quitter avant la fin de l'upload (20-30 s), au prochain boot
  /// `AppDatabase.init()` reprend automatiquement.
  ///
  /// Ancien comportement (`Future.microtask` + `StorageService.uploadImage
  /// Bytes` direct + `AppDatabase.saveProduct`) perdait les bytes en
  /// mémoire JS si le user quittait avant la fin — image disparue
  /// silencieusement. Le service gère désormais retry, cap FIFO 50,
  /// suppression de l'ancienne image, et update du `Product` en Hive.
  Future<void> _uploadImagesInBackground(Product product, int baseTs) async {
    final shopId = widget.shopId;
    final productId = product.id;
    if (productId == null) return;

    for (int i = 0; i < _variants.length; i++) {
      if (i >= product.variants.length) break;
      final v = _variants[i];

      if (v.imageBytes != null) {
        await PendingImageUploadService.enqueue(
          shopId:     shopId,
          productId:  productId,
          variantIdx: i,
          bytes:      v.imageBytes!,
          name:       'shops/$shopId/products/${baseTs}_$i',
          mimeType:   'image/png',
          isPrimary:  true,
        );
      }
      for (int j = 0; j < v.secondaryImageBytes.length; j++) {
        await PendingImageUploadService.enqueue(
          shopId:     shopId,
          productId:  productId,
          variantIdx: i,
          bytes:      v.secondaryImageBytes[j],
          name:       'shops/$shopId/products/${baseTs}_${i}_sec_$j',
          mimeType:   'image/png',
          isPrimary:  false,
        );
      }
    }

    // Flush immédiat : sur connexion rapide (wifi/4G stable) l'upload se
    // termine en 1-3 s, équivalent comportement ancien microtask. Sur 3G
    // ou si le user ferme l'onglet, le worker reprendra au boot suivant
    // ou à la reconnexion (hooks dans AppDatabase.init/_onNetworkRestored).
    unawaited(PendingImageUploadService.flush());
  }

  /// Demande la source de l'image. Sur le web de bureau, « Prendre une
  /// photo » retombe d'elle-même sur le sélecteur de fichiers : c'est le
  /// comportement natif d'image_picker, on ne le contrarie pas.
  Future<ImageSource?> _askImageSource() => showFormSheet<ImageSource>(
    context: context,
    builder: (dc) => SafeArea(
      top: false,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const FormSheetHeader(
            title: 'Ajouter une image', icon: Icons.add_a_photo_outlined),
        Divider(height: 1, color: Theme.of(dc).semantic.borderSubtle),
        ListTile(
          leading: Icon(Icons.photo_camera_outlined,
              size: 20, color: AppColors.primary),
          title: const Text('Prendre une photo'),
          onTap: () => Navigator.of(dc).pop(ImageSource.camera),
        ),
        ListTile(
          leading: Icon(Icons.photo_library_outlined,
              size: 20, color: AppColors.primary),
          title: const Text('Choisir dans la galerie'),
          onTap: () => Navigator.of(dc).pop(ImageSource.gallery),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );

  Future<void> _pickImage({int variantIdx = 0}) async {
    final source = await _askImageSource();
    if (source == null || !mounted) return;
    // Pas de maxWidth / imageQuality sur ImagePicker : sur web ils
    // peuvent forcer une recompression JPEG silencieuse et tuer la
    // transparence. On lit les bytes bruts puis `validateAndReadImage`
    // décode, valide la résolution (min 800×800), redimensionne à
    // 1600 px max et ré-encode en PNG lossless. Les bytes stockés dans
    // `_variants[].imageBytes` sont donc DÉJÀ du PNG prêt à uploader —
    // l'upload doit passer `mimeType: 'image/png'`, sinon Supabase
    // enregistre du PNG sous extension .jpg.
    final xFile = await ImagePicker().pickImage(source: source);
    if (xFile == null || !mounted) return;
    final result = await validateAndReadImage(xFile, context);
    if (!mounted || !result.isValid) return;
    setState(() => _variants[variantIdx].imageBytes = result.bytes);
    _showImageSavedSnack(result.width, result.height);
  }

  Future<void> _pickSecondaryImage({int variantIdx = 0}) async {
    final source = await _askImageSource();
    if (source == null || !mounted) return;
    final xFile = await ImagePicker().pickImage(source: source);
    if (xFile == null || !mounted) return;
    final result = await validateAndReadImage(xFile, context);
    if (!mounted || !result.isValid) return;
    setState(() => _variants[variantIdx].secondaryImageBytes.add(result.bytes!));
    _showImageSavedSnack(result.width, result.height);
  }

  void _showImageSavedSnack(int w, int h) {
    if (!mounted) return;
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(context.l10n.imageSaved(w, h)),
      backgroundColor: theme.semantic.success,
      duration: const Duration(seconds: 2),
    ));
  }

  /// Bottom sheet pour ajouter rapidement une marque / catégorie / unité.
  /// Refonte UX : remplace l'AlertDialog par un FormSheet verrouillé
  /// (pas de tap-outside, X intégré au header).
  Future<String?> _addItemDialog(BuildContext ctx, String title, String hint,
      Future<String> Function(String) onSave) async {
    final ctrl = TextEditingController();
    return showFormSheet<String>(
      context: ctx,
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
                  title: title,
                  icon: Icons.add_box_outlined,
                ),
                Divider(height: 1, color: Theme.of(dc).semantic.borderSubtle),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: TextFormField(
                    controller: ctrl,
                    autofocus: true,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF1A1D2E)),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: const TextStyle(
                          color: Color(0xFFBBBBBB), fontSize: 12),
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
                        child: Text(context.l10n.invCancel),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 44),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () async {
                          final v = ctrl.text.trim();
                          if (v.isNotEmpty) {
                            final saved = await onSave(v);
                            if (dc.mounted) {
                              Navigator.of(dc).pop(saved);
                            }
                          }
                        },
                        child: Text(context.l10n.add),
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
  }

  List<String> _stepTitles(AppLocalizations l) => [
    l.prodGeneralInfo,
    l.prodIdentificationVariants,
    l.prodMedia,
  ];

  static const _stepIcons = [
    Icons.info_outline_rounded,
    Icons.layers_outlined,
    Icons.photo_library_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    final titles = _stepTitles(l);
    return PopScope(
      // Retour système / geste / bouton Android. La flèche de l'AppBar, elle,
      // passe par `onBeforeBack` : un `context.pop()` programmatique n'est
      // pas interceptable ici.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final canLeave = await _confirmExit();
        // `context.mounted` et non `mounted` : l'analyseur ne reconnaît pas
        // le drapeau du State comme protégeant CE context après un `await`.
        if (canLeave && context.mounted) context.pop();
      },
      child: AppScaffold(
      shopId: widget.shopId,
      title: widget.extra != null ? 'Modifier le produit' : l.inventaireAdd,
      isRootPage: false,
      onBeforeBack: _confirmExit,
      body: Column(children: [
        _StepBar(current: _step, total: _totalSteps,
            titles: titles, icons: _stepIcons, onTap: _goTo),
        _ProfileProgressBar(value: _profileCompletion),
        Expanded(child: PageView(
          controller: _pageCtrl,
          physics: const NeverScrollableScrollPhysics(),
          onPageChanged: (i) => setState(() => _step = i),
          children: [_buildStep1(l), _buildStep2(l), _buildStep3(l)],
        )),
        _BottomNav(step: _step, total: _totalSteps,
            onPrev: _prev, onNext: _next, onSubmit: _submit,
            isSaving: _isSaving),
      ]),
    ));
  }

  // ══════════════════════════════════════════════════════════════════
  // ÉTAPE 1 — Informations générales (inchangée)
  // ══════════════════════════════════════════════════════════════════
  Widget _buildStep1(AppLocalizations l) => _StepScroll(
    formKey: _keys[0],
    children: [
      AppSectionCard(title: l.prodGeneralInfo, icon: Icons.info_outline_rounded, children: [
        _LF(l.inventaireName, req: true,
            child: _TF(_nameCtrl, 'Ex: Coca-Cola 33cl', Icons.label_outline,
                autofocus: true,
                // Rafraîchit la barre de complétude à la frappe.
                onChanged: (_) => setState(() {}),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Requis' : null)),
        _gap(),
        _LF(l.prodBrand, req: _isCreating,
            child: AppSelectWidget(
              label: '', required: false, items: _brands,
              value: _brand.isEmpty ? null : _brand,
              icon: Icons.verified_outlined, addLabel: l.prodAddBrand,
              onChanged: (v) => setState(() => _brand = v),
              onAdd: (ctx) => _addItemDialog(ctx, l.prodAddBrand,
                  l.prodBrandHint, (v) async {
                    await AppDatabase.saveBrand(widget.shopId, v);
                    setState(() => _brands = LocalStorageService.getBrands(widget.shopId));
                    return v;
                  }),
              onDelete: (item) async {
                try {
                  await AppDatabase.deleteBrand(widget.shopId, item);
                  setState(() {
                    _brands = LocalStorageService.getBrands(widget.shopId);
                    if (_brand == item) _brand = '';
                  });
                } catch (e) {
                  if (mounted) _showError(e.toString().replaceAll('Exception: ', ''));
                }
              },
              onRename: (oldName, newName) async {
                await AppDatabase.renameBrand(widget.shopId, oldName, newName);
                setState(() {
                  _brands = LocalStorageService.getBrands(widget.shopId);
                  if (_brand == oldName) _brand = newName;
                });
              },
            )),
        _gap(),
        _LF(l.prodCategory, req: _isCreating,
            child: AppSelectWidget(
              label: '', required: false, items: _categories,
              value: _category.isEmpty ? null : _category,
              icon: Icons.category_outlined, addLabel: l.prodAddCategory,
              onChanged: (v) => setState(() => _category = v),
              onAdd: (ctx) => _addItemDialog(ctx, l.prodAddCategory,
                  l.prodCategoryHint, (v) async {
                    await AppDatabase.saveCategory(widget.shopId, v);
                    setState(() => _categories = LocalStorageService.getCategories(widget.shopId));
                    return v;
                  }),
              onDelete: (item) async {
                try {
                  await AppDatabase.deleteCategory(widget.shopId, item);
                  setState(() {
                    _categories = LocalStorageService.getCategories(widget.shopId);
                    if (_category == item) _category = '';
                  });
                } catch (e) {
                  if (mounted) _showError(e.toString().replaceAll('Exception: ', ''));
                }
              },
              onRename: (oldName, newName) async {
                await AppDatabase.renameCategory(widget.shopId, oldName, newName);
                setState(() {
                  _categories = LocalStorageService.getCategories(widget.shopId);
                  if (_category == oldName) _category = newName;
                });
              },
            )),
        _gap(),
        _LF(l.prodUnitType,
            child: AppSelectWidget(
              label: '', required: false, items: _units,
              value: _unit.isEmpty ? null : _unit,
              icon: Icons.straighten_rounded, addLabel: l.prodAddUnit,
              onChanged: (v) => setState(() => _unit = v),
              onAdd: (ctx) => _addItemDialog(ctx, l.prodAddUnit,
                  l.prodUnitHint, (v) async {
                    await AppDatabase.saveUnit(widget.shopId, v);
                    setState(() => _units = LocalStorageService.getUnits(widget.shopId));
                    return v;
                  }),
              onDelete: (item) async {
                try {
                  await AppDatabase.deleteUnit(widget.shopId, item);
                  setState(() {
                    _units = LocalStorageService.getUnits(widget.shopId);
                    if (_unit == item) _unit = '';
                  });
                } catch (e) {
                  if (mounted) _showError(e.toString().replaceAll('Exception: ', ''));
                }
              },
              onRename: (oldName, newName) async {
                await AppDatabase.renameUnit(widget.shopId, oldName, newName);
                setState(() {
                  _units = LocalStorageService.getUnits(widget.shopId);
                  if (_unit == oldName) _unit = newName;
                });
              },
            )),
        _gap(),
        // Avertissement non bloquant en MODIFICATION : un produit ancien peut
        // ne pas avoir de marque/catégorie. On le signale sans empêcher
        // l'enregistrement. Un message fugace serait écrasé par celui de
        // succès — d'où un bandeau permanent.
        if (!_isCreating &&
            (_category.trim().isEmpty || _brand.trim().isEmpty)) ...[
          _WarnBanner(_missingTaxonomyWarning()),
          _gap(),
        ],
        _LF(l.prodDescription,
            child: _TF(_descCtrl, 'Description visible par les clients…',
                Icons.notes_rounded, maxLines: 3)),
        _gap(),
        _LF(l.prodNotes,
            child: _TF(_notesCtrl, l.prodNotesHint,
                Icons.sticky_note_2_outlined, maxLines: 2)),
      ]),
      _gap(h: 14),
      // Fournisseur (facultatif) — replié par défaut, dépliable au besoin.
      // Auto-déplié en édition si un fournisseur/référence est déjà renseigné.
      _ExpandSection(
        icon: Icons.local_shipping_rounded,
        label: 'Fournisseur (facultatif)',
        forceOpen: _selectedSupplier != null
            || _supplierRefCtrl.text.trim().isNotEmpty,
        children: [
          _LF('Nom du fournisseur',
              child: _SupplierPickField(
                controller: _supplierCtrl,
                suppliers: _suppliers,
                selected: _selectedSupplier,
                onPicked: (s) => setState(() {
                  _selectedSupplier = s;
                  _supplierCtrl.text = s.name;
                }),
                onCleared: () => setState(() {
                  _selectedSupplier = null;
                  _supplierCtrl.clear();
                }),
                onManualChange: (text) {
                  // Si l'utilisateur retape, on tente de re-matcher ; sinon on
                  // considère que c'est une saisie libre (fournisseur hors liste).
                  final match = _matchSupplierByName(text);
                  if (match?.id != _selectedSupplier?.id) {
                    setState(() => _selectedSupplier = match);
                  }
                },
              )),
          if (_selectedSupplier != null) ...[
            _gap(h: 8),
            _SupplierInfoCard(supplier: _selectedSupplier!),
          ],
          _gap(),
          _LF('Référence fournisseur',
              child: _TF(_supplierRefCtrl, 'Ex: REF-001',
                  Icons.tag_rounded)),
        ],
      ),
    ],
  );

  // ══════════════════════════════════════════════════════════════════
  // ÉTAPE 2 — Variantes & Tarification
  // ══════════════════════════════════════════════════════════════════
  Widget _buildStep2(AppLocalizations l) => _StepScroll(
    formKey: _keys[1],
    children: [
      AppSectionCard(title: l.prodIdentificationVariants, icon: Icons.layers_outlined, children: [
        _InfoBanner(l.prodVariantBaseHint),
        _gap(h: 8),
        ...List.generate(_variants.length, (i) {
          final v = _variants[i];
          return _VariantFullCard(
            key: ValueKey('variant_$i'),
            variant: v, index: i,
            isBase: i == 0, isMain: v.isMain, isExpanded: v.isExpanded,
            expensePerUnit: _expensePerUnit,
            onToggleExpand: () => setState(() => v.isExpanded = !v.isExpanded),
            onRemove: i == 0 ? null : () => _confirmRemoveVariant(v),
            onChanged:             () => setState(() {}),
            onPickImage:           () => _pickImage(variantIdx: i),
            onPickSecondaryImage:  () => _pickSecondaryImage(variantIdx: i),
            onRemoveSecondaryImage: (idx, isUrl) => setState(() {
              if (isUrl) {
                _variants[i].secondaryImageUrls.removeAt(idx);
              } else {
                _variants[i].secondaryImageBytes.removeAt(idx);
              }
            }),
            onSetMain: () => setState(() {
              for (final vv in _variants) vv.isMain = false;
              v.isMain = true;
            }),
            onPromoToggle:    (val) => setState(() => v.promoEnabled = val),
            onPromoStartPick: (d)   => setState(() => v.promoStart = d),
            onPromoEndPick:   (d)   => setState(() => v.promoEnd   = d),
            productId: _editingProduct?.id,
            shopId:    widget.shopId,
            showWebPrice: _isVisibleWeb,
            skuValidator: (val) {
              if ((val ?? '').trim().isEmpty) return 'Requis';
              final sku = val!.trim().toLowerCase();
              for (int j = 0; j < _variants.length; j++) {
                if (j == i) continue;
                if (_variants[j].sku.text.trim().toLowerCase() == sku) {
                  return 'SKU déjà utilisé par une autre variante';
                }
              }
              return null;
            },
            onSkuChanged: (val) => _onSkuChanged(val, v),
          );
        }),
        _gap(h: 4),
        GestureDetector(
          onTap: () => setState(() {
            for (final v in _variants) v.isExpanded = false;
            final prev = _variants.last;
            final nv = _Variant()..isExpanded = true;
            // Pré-remplir avec les données de la variante précédente
            nv.purchasePrice.text = prev.purchasePrice.text;
            nv.salePricePos.text  = prev.salePricePos.text;
            nv.salePriceWeb.text  = prev.salePriceWeb.text;
            nv.supplier.text      = prev.supplier.text;
            nv.supplierRef.text   = prev.supplierRef.text;
            nv.stock.text         = prev.stock.text;
            nv.stockAlert.text    = prev.stockAlert.text;
            _variants.add(nv);
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).semantic.borderSubtle),
              color: AppColors.surface,
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.add_rounded, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(l.prodAddVariant, style: TextStyle(fontSize: 12,
                  color: AppColors.primary, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      ]),
      _gap(h: 14),

      // TVA
      AppSectionCard(title: l.prodTaxRate, icon: Icons.percent_rounded, children: [
        _LF(l.prodTaxRate,
            child: _TF(_taxRateCtrl, '0', Icons.percent_rounded,
                keyboardType: TextInputType.number)),
      ]),
      _gap(h: 14),

      // Dépenses communes
      AppSectionCard(title: l.prodExpenses, icon: Icons.receipt_long_rounded, trailing: _AddBtn(l.prodAddExpense, () {
        final ex = _Expense();
        ex.amount.addListener(() => setState(() {}));
        setState(() => _expenses.add(ex));
      }),
        children: [
          _InfoBanner(
              'Les dépenses (transport, emballage…) sont réparties proportionnellement '
                  'au stock total et ajoutées au prix de revient de chaque variante.'),
          if (_expenses.isNotEmpty) _gap(h: 8),
          ...List.generate(_expenses.length, (i) => _ExpRow(
            expense: _expenses[i], index: i,
            onRemove: () => setState(() {
              _expenses[i].dispose(); _expenses.removeAt(i);
            }),
            onChanged: () => setState(() {}),
          )),
          if (_expenses.isNotEmpty && _totalStock > 0) ...[
            _gap(h: 6),
            _CalcBanner(
              label: l.prodExpensePerUnit,
              value: '${CurrencyFormatter.format(_expensePerUnit.ceilToDouble())}/u',
              sub: '${CurrencyFormatter.format(_totalExpenses)} ÷ $_totalStock u',
            ),
          ],
        ],
      ),
    ],
  );

  // ══════════════════════════════════════════════════════════════════
  // ÉTAPE 3 — Médias & visibilité (sans poids/dims)
  // ══════════════════════════════════════════════════════════════════
  Widget _buildStep3(AppLocalizations l) => _StepScroll(
    formKey: _keys[2],
    children: [
      AppSectionCard(title: l.prodMainImage, icon: Icons.photo_library_outlined, children: [
        _InfoBanner(l.prodMainImageHint),
        _gap(h: 10),
        SizedBox(
          height: 90,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _variants.length,
            itemBuilder: (_, i) {
              final v      = _variants[i];
              final isMain = v.isMain;
              return GestureDetector(
                onTap: () => setState(() {
                  for (final vv in _variants) vv.isMain = false;
                  _variants[i].isMain = true;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  margin: const EdgeInsets.only(right: 8),
                  width: 80,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: isMain ? AppColors.primary : Theme.of(context).semantic.borderSubtle,
                        width: isMain ? 2 : 1),
                  ),
                  child: Stack(fit: StackFit.expand, children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(9),
                      child: _buildVariantImage(
                        context: context,
                        displaySize: 80,
                        bytes: v.imageBytes,
                        url:   v.imageUrl,
                        placeholder: _ImgPlaceholderSmall(),
                      ),
                    ),
                    if (isMain)
                      Positioned(top: 4, right: 4,
                          child: Container(
                            width: 20, height: 20,
                            decoration: BoxDecoration(
                                color: AppColors.primary, shape: BoxShape.circle),
                            child: const Icon(Icons.star_rounded,
                                size: 12, color: Colors.white),
                          )),
                    Positioned(bottom: 0, left: 0, right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha:0.45),
                            borderRadius: const BorderRadius.only(
                                bottomLeft: Radius.circular(9),
                                bottomRight: Radius.circular(9)),
                          ),
                          child: Text(
                            i == 0 ? l.prodBaseVariant : '${l.prodVariants} $i',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 9,
                                color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        )),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
      _gap(h: 14),
      AppSectionCard(title: l.prodVisibility, icon: Icons.visibility_outlined, children: [
        _ToggleRow(l.prodIsActive, l.caisseActiveHint,
            _isActive, AppColors.secondary,
                (v) => setState(() => _isActive = v)),
        Divider(height: 18, color: Theme.of(context).semantic.borderSubtle),
        _ToggleRow(l.prodIsVisibleWeb, l.webShopVisibleHint,
            _isVisibleWeb, AppColors.primary,
                (v) => setState(() => _isVisibleWeb = v)),
        Divider(height: 18, color: Theme.of(context).semantic.borderSubtle),
        // Suivi de stock (hotfix_138). Décoché = plat cuisiné, service ou
        // prestation : les ventes ne décrémentent rien et les annulations
        // ne recréditent rien.
        _ToggleRow(l.prodTrackStock, l.trackStockHint,
            _trackStock, AppColors.secondary,
                (v) => setState(() => _trackStock = v)),
        Divider(height: 18, color: Theme.of(context).semantic.borderSubtle),
        _LF(l.prodRating,
            child: _Stars(_rating, (v) => setState(() => _rating = v))),
      ]),
    ],
  );
} // fin _ProductFormPageState

// ─── Card variante repliable ──────────────────────────────────────────────────

class _VariantFullCard extends StatelessWidget {
  final _Variant  variant;
  final int       index;
  final bool      isBase;
  final bool      isMain;
  final bool      isExpanded;
  final double    expensePerUnit;
  final VoidCallback?           onRemove;
  final VoidCallback            onChanged;
  final VoidCallback            onPickImage;
  final VoidCallback            onPickSecondaryImage;
  final void Function(int, bool) onRemoveSecondaryImage;
  final VoidCallback            onSetMain;
  final VoidCallback            onToggleExpand;
  final void Function(bool)     onPromoToggle;
  final void Function(DateTime) onPromoStartPick;
  final void Function(DateTime) onPromoEndPick;
  final String? productId;
  final String? shopId;
  final bool showWebPrice;
  final String? Function(String?)? skuValidator;
  /// Remonte chaque frappe du SKU au formulaire, qui pilote l'anti-rebond.
  final void Function(String)? onSkuChanged;

  const _VariantFullCard({
    super.key,
    required this.variant,
    required this.index,
    required this.isBase,
    required this.isMain,
    required this.isExpanded,
    required this.expensePerUnit,
    required this.onRemove,
    required this.onChanged,
    required this.onPickImage,
    required this.onPickSecondaryImage,
    required this.onRemoveSecondaryImage,
    required this.onSetMain,
    required this.onToggleExpand,
    required this.onPromoToggle,
    required this.onPromoStartPick,
    required this.onPromoEndPick,
    this.productId,
    this.shopId,
    this.showWebPrice = false,
    this.skuValidator,
    this.onSkuChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    final buy    = double.tryParse(variant.purchasePrice.text) ?? 0;
    final sell   = double.tryParse(variant.salePricePos.text)  ?? 0;
    final eff    = buy > 0 ? (buy + expensePerUnit).ceilToDouble() : 0.0;
    final benef  = sell > 0 && eff > 0 ? sell - eff : 0.0;
    final margin = sell > 0 && eff > 0 ? benef / sell * 100 : 0.0;
    final hasImg = variant.imageBytes != null ||
        (variant.imageUrl != null && variant.imageUrl!.isNotEmpty);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: isMain ? AppColors.primarySurface : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isMain
                ? AppColors.primary.withValues(alpha:0.4)
                : Theme.of(context).semantic.borderSubtle,
            width: isMain ? 1.5 : 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // ── En-tête ───────────────────────────────────────────────
        GestureDetector(
          onTap: onToggleExpand,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: isMain ? AppColors.primary : AppColors.primarySurface,
                    borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (isMain) ...[
                    const Icon(Icons.star_rounded, size: 10, color: Colors.white),
                    const SizedBox(width: 4),
                  ],
                  Text(isBase ? l.prodBaseVariant : '${l.prodVariants} $index',
                      style: TextStyle(fontSize: 11,
                          color: isMain ? Colors.white : AppColors.primary,
                          fontWeight: FontWeight.w600)),
                ]),
              ),
              const SizedBox(width: 8),
              // Aperçu replié
              // Image variante (visible en collapsed ET expanded)
              if (hasImg) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 32, height: 32,
                    child: _buildVariantImage(
                      context: context,
                      displaySize: 32,
                      bytes: variant.imageBytes,
                      url:   variant.imageUrl,
                      placeholder: const SizedBox(width: 32, height: 32),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (!isExpanded) ...[
                Expanded(child: Text(
                  variant.name.text.isEmpty ? '—' : variant.name.text,
                  style: TextStyle(fontSize: 12,
                      color: AppColors.onSurface, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                )),
                if (sell > 0)
                  Text(CurrencyFormatter.format(sell),
                      style: TextStyle(fontSize: 11,
                          color: AppColors.primary, fontWeight: FontWeight.w600)),
              ] else
                const Spacer(),

              if (!isMain) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: onSetMain,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primarySurface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.primary.withValues(alpha:0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.star_outline_rounded, size: 12,
                          color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text(l.prodSetMain,
                          style: TextStyle(fontSize: 10,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ],
              if (onRemove != null) ...[
                const SizedBox(width: 4),
                IconButton(
                    onPressed: onRemove,
                    icon: Icon(Icons.close_rounded, size: 16,
                        color: AppColors.textHint),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24)),
              ],
              const SizedBox(width: 2),
              Icon(isExpanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
                  size: 18, color: AppColors.textHint),
            ]),
          ),
        ),

        // ── Contenu dépliable ─────────────────────────────────────
        if (isExpanded) ...[
          const Divider(height: 1, color: Color(0xFFEEEEEE)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // Hint qualité image (emplacement B — au-dessus du Row
              // image+nom+SKU, sur toute la largeur du panneau variante).
              Text(
                l.imageUploadHint,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textHint,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 6),

              // Image + Nom + SKU
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                GestureDetector(
                  onTap: onPickImage,
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 64, height: 64,
                        child: hasImg
                            ? _buildVariantImage(
                                context: context,
                                displaySize: 64,
                                bytes: variant.imageBytes,
                                url:   variant.imageUrl,
                                placeholder: _ImgPlaceholderSmall(),
                              )
                            : Container(
                                decoration: BoxDecoration(
                                    color: AppColors.inputFill,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
                                child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_photo_alternate_outlined,
                                          size: 20, color: AppColors.textHint),
                                      const SizedBox(height: 2),
                                      Text(l.prodChooseFile,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 8,
                                              color: AppColors.textHint)),
                                    ])),
                      ),
                    ),
                    if (hasImg)
                      Positioned(bottom: 0, right: 0,
                          child: Container(
                            width: 18, height: 18,
                            decoration: BoxDecoration(
                                color: AppColors.primary, shape: BoxShape.circle),
                            child: const Icon(Icons.edit_rounded,
                                size: 10, color: Colors.white),
                          )),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(child: _Row2([
                  _LF(l.prodVariantName, req: true,
                      child: _TF(variant.name,
                          isBase ? l.prodBaseVariantHint : 'Ex: Rouge XL',
                          Icons.label_outline,
                          onChanged: (_) => onChanged(),
                          validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Requis' : null)),
                  _LF(l.prodSku, req: true,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _TF(variant.sku,
                              isBase ? 'PROD-001' : 'PROD-001-R',
                              Icons.tag_rounded,
                              onChanged: onSkuChanged,
                              suffix: _SkuStatusDot(status: variant.skuStatus),
                              validator: skuValidator ?? (v) =>
                              (v ?? '').trim().isEmpty ? 'Requis' : null),
                          if (variant.skuStatus == _SkuStatus.taken)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                variant.skuConflictName == null
                                    ? 'Ce SKU est déjà utilisé'
                                    : 'Ce SKU est utilisé par '
                                      '« ${variant.skuConflictName} »',
                                style: const TextStyle(fontSize: 11,
                                    color: AppColors.error, height: 1.3)),
                            ),
                        ],
                      )),
                ])),
              ]),
              _gap(h: 10),

              // Images secondaires
              if (variant.secondaryImageBytes.isNotEmpty ||
                  variant.secondaryImageUrls.isNotEmpty) ...[
                _SecondaryImagesRow(
                  bytesList: variant.secondaryImageBytes,
                  urls:      variant.secondaryImageUrls,
                  onAdd:     onPickSecondaryImage,
                  onRemoveItem: onRemoveSecondaryImage,
                ),
                _gap(h: 10),
              ] else ...[
                GestureDetector(
                  onTap: onPickSecondaryImage,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppColors.primarySurface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha:0.3)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.add_photo_alternate_outlined,
                          size: 14, color: AppColors.primary),
                      const SizedBox(width: 6),
                      Text('Ajouter images secondaires',
                          style: TextStyle(fontSize: 11,
                              color: AppColors.primary,
                              fontWeight: FontWeight.w500)),
                    ]),
                  ),
                ),
                _gap(h: 10),
              ],

              // Barcode
              _LF(l.prodBarcode,
                  child: _TF(variant.barcode, '6009123…',
                      Icons.qr_code_scanner_rounded)),
              _gap(h: 10),

              // Prix achat (obligatoire) + prix de vente (optionnel à la création)
              _Row2([
                _LF(l.prodPurchasePrice, req: true,
                    child: _TF(variant.purchasePrice, '0',
                        Icons.attach_money_rounded,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => onChanged(),
                        validator: (v) =>
                        (v ?? '').trim().isEmpty ? 'Requis' : null)),
                _LF(productId != null ? l.prodSalePrice : 'Prix de vente (fixé à l\'arrivée)',
                    child: _TF(variant.salePricePos, '0',
                        Icons.sell_outlined,
                        keyboardType: TextInputType.number,
                        onChanged: (_) => onChanged())),
              ]),
              // Prix web — uniquement si isVisibleWeb est activé
              if (showWebPrice) ...[
                _gap(h: 8),
                _LF(l.prodPriceSellWeb,
                    child: _TF(variant.salePriceWeb, '0',
                        Icons.language_rounded,
                      keyboardType: TextInputType.number)),
              ],
              _gap(h: 10),

              // Stock + Stock min (OBLIGATOIRES)
              // - Création de produit (productId == null) : champ stock saisi.
              // - Nouvelle variante dans produit existant (variant.isNew)    : idem,
              //   pour permettre la saisie du stock initial.
              // - Variante déjà persistée : indicateurs 4 champs + bouton Corriger.
              if (productId != null && !variant.isNew) ...[
                _StockIndicators(
                    productId: productId!, shopId: shopId ?? '',
                    variantIndex: index,
                    onAdjusted: onChanged),
                _gap(h: 8),
              ],
              if (productId == null || variant.isNew)
                _Row2([
                  _LF(l.prodVariantStock, req: true,
                      child: _TF(variant.stock, '0',
                          Icons.inventory_2_outlined,
                          keyboardType: TextInputType.number,
                          onChanged: (_) => onChanged(),
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? 'Requis' : null)),
                  _LF(l.prodStockMinAlert, req: true,
                      child: _TF(variant.stockAlert, '1',
                          Icons.warning_amber_rounded,
                          keyboardType: TextInputType.number,
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? 'Requis' : null)),
                ])
              else
                _LF(l.prodStockMinAlert, req: true,
                    child: _TF(variant.stockAlert, '1',
                        Icons.warning_amber_rounded,
                        keyboardType: TextInputType.number,
                        validator: (v) =>
                            (v ?? '').trim().isEmpty ? 'Requis' : null)),

              // Bannière bénéfice
              if (buy > 0 && sell > 0) ...[
                _gap(h: 10),
                _BenefitBanner(
                    effectiveCost: eff, benefit: benef,
                    margin: margin, expensePerUnit: expensePerUnit, l: l),
              ],
              _gap(h: 10),

              // Promotion (repliable)
              _ExpandSection(
                icon: Icons.local_offer_outlined,
                label: l.prodPriceHistory,
                trailing: Transform.scale(
                  scale: 0.8,
                  child: AppSwitch(value: variant.promoEnabled,
                    onChanged: onPromoToggle,
                  ),
                ),
                forceOpen: variant.promoEnabled,
                children: variant.promoEnabled ? [
                  _LF(l.prodPromoPrice,
                      child: _TF(variant.promoPrice, '0',
                          Icons.local_offer_outlined,
                          keyboardType: TextInputType.number)),
                  _gap(h: 8),
                  _Row2([
                    _LF(l.prodPromoStart, child: _DateBtn(
                        date: variant.promoStart, hint: 'jj/mm/aaaa',
                        onPick: onPromoStartPick)),
                    _LF(l.prodPromoEnd, child: _DateBtn(
                        date: variant.promoEnd, hint: 'jj/mm/aaaa',
                        onPick: onPromoEndPick)),
                  ]),
                ] : [],
              ),
              _gap(h: 8),

              // Poids & dimensions (repliable)
              _ExpandSection(
                icon: Icons.straighten_rounded,
                label: l.prodWeightDims,
                children: [
                  _Row2([
                    _LF(l.prodWeight,
                        child: _TF(variant.weight, '0', Icons.scale_outlined,
                            keyboardType: TextInputType.number)),
                    _LF(l.prodLength,
                        child: _TF(variant.length, '0',
                            Icons.straighten_rounded,
                            keyboardType: TextInputType.number)),
                  ]),
                  _gap(h: 8),
                  _Row2([
                    _LF(l.prodWidth,
                        child: _TF(variant.width, '0',
                            Icons.width_normal_rounded,
                            keyboardType: TextInputType.number)),
                    _LF(l.prodHeight,
                        child: _TF(variant.height, '0',
                            Icons.height_rounded,
                            keyboardType: TextInputType.number)),
                  ]),
                ],
              ),

              // Arrivées en stock (uniquement en mode édition)
              if (productId != null && shopId != null) ...[
                _gap(h: 8),
                _StockArrivalsSection(
                  key: ValueKey('arrivals_${productId}_${index}_${HiveBoxes.stockArrivalsBox.length}'),
                  productId: productId,
                  shopId: shopId ?? '',
                  variantIndex: index,
                  variantName: variant.name.text,
                  onStockChanged: onChanged,
                ),
              ],
            ]),
          ),
        ],
      ]),
    );
  }
}

// ─── Section arrivées en stock dans fiche variante ──────────────────────────

class _StockArrivalsSection extends StatefulWidget {
  final String? productId;
  final String shopId;
  final int variantIndex;
  final String variantName;
  final VoidCallback onStockChanged;
  const _StockArrivalsSection({super.key, this.productId,
    required this.shopId, required this.variantIndex,
    required this.variantName, required this.onStockChanged});
  @override State<_StockArrivalsSection> createState() => _StockArrivalsSectionState();
}

class _StockArrivalsSectionState extends State<_StockArrivalsSection> {
  List<StockArrival> _arrivals = [];
  bool _expanded = false;

  @override void initState() { super.initState(); _load(); }

  void _load() {
    final pid = widget.productId;
    if (pid == null) { _arrivals = []; return; }
    final vid = _resolvedVariantId;
    setState(() {
      _arrivals = HiveBoxes.stockArrivalsBox.values
          .map((m) {
            try { return StockArrival.fromMap(Map<String, dynamic>.from(m)); }
            catch (_) { return null; }
          })
          .whereType<StockArrival>()
          .where((a) {
            if (a.shopId != widget.shopId) return false;
            // Filtrer par variant_id si disponible
            if (vid != null && a.variantId != null && a.variantId!.isNotEmpty) {
              return a.variantId == vid;
            }
            return a.productId == pid;
          })
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    });
  }

  String? get _resolvedVariantId {
    if (widget.productId == null) return null;
    final products = AppDatabase.getProductsForShop(widget.shopId);
    final p = products.where((p) => p.id == widget.productId).firstOrNull;
    if (p != null && widget.variantIndex < p.variants.length) {
      return p.variants[widget.variantIndex].id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.productId == null) return const SizedBox.shrink();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Icon(Icons.inventory_rounded, size: 14, color: AppColors.primary),
            const SizedBox(width: 6),
            Expanded(child: Text('Arrivées en stock',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: AppColors.primary))),
            if (_arrivals.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(color: AppColors.primary.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('${_arrivals.length}', style: TextStyle(fontSize: 9,
                    fontWeight: FontWeight.w700, color: AppColors.primary)),
              ),
            // Correction 1 : bouton centré
            GestureDetector(
              onTap: () => _showArrivalSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: AppColors.primary, borderRadius: BorderRadius.circular(6)),
                child: Row(mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.add_rounded, size: 12, color: Colors.white),
                  const SizedBox(width: 4),
                  const Text('Arrivée', style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w600, color: Colors.white)),
                ]),
              ),
            ),
            const SizedBox(width: 6),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                size: 16, color: AppColors.textHint),
          ]),
        ),
      ),
      // Liste avec actions modifier/supprimer
      if (_expanded && _arrivals.isNotEmpty)
        ...(_arrivals.take(10).map((a) => Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: a.isAvailable ? AppColors.secondary.withValues(alpha: 0.12) : AppColors.error.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: a.isAvailable
                ? const Color(0xFFA7F3D0) : const Color(0xFFFCA5A5))),
          child: Row(children: [
            Icon(a.isAvailable ? Icons.check_circle_rounded : Icons.warning_rounded,
                size: 14, color: a.isAvailable
                    ? AppColors.secondary : AppColors.error),
            const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('+${a.quantity} · ${a.cause.label}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              Text('${a.statusLabel} · ${_fmtDate(a.createdAt)}',
                  style: TextStyle(fontSize: 9, color: AppColors.textHint)),
              if (a.note != null && a.note!.isNotEmpty)
                Text(a.note!, style: TextStyle(fontSize: 9,
                    color: AppColors.textSecondary, fontStyle: FontStyle.italic),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
            ])),
            // Correction 2 : boutons modifier/supprimer
            GestureDetector(
              onTap: () => _showArrivalSheet(context, existing: a),
              child: Padding(padding: const EdgeInsets.all(4),
                  child: Icon(Icons.edit_rounded, size: 14,
                      color: AppColors.primary.withValues(alpha:0.6))),
            ),
            GestureDetector(
              onTap: () => _confirmDelete(context, a),
              child: const Padding(padding: EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline_rounded, size: 14,
                      color: AppColors.error)),
            ),
          ]),
        ))),
      if (_expanded && _arrivals.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('Aucune arrivée enregistrée',
              style: TextStyle(fontSize: 11, color: AppColors.textHint)),
        ),
    ]);
  }

  String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  // ── Correction 2 : suppression avec confirmation ────────────────────────
  Future<void> _confirmDelete(BuildContext context, StockArrival arrival) async {
    final ref = arrival.id.length >= 6
        ? arrival.id.substring(arrival.id.length - 6)
        : arrival.id;
    final ok = await DangerConfirmDialog.show(
      context: context,
      title: 'Supprimer cette arrivée de stock',
      description: '+${arrival.quantity} · ${arrival.cause.label} · '
          '${arrival.statusLabel}',
      consequences: const [
        'Le mouvement de stock correspondant sera annulé.',
        'L\'incident lié (si présent) sera également supprimé.',
      ],
      confirmText: ref,
      onConfirmed: () {},
    );
    if (ok != true || !mounted) return;
    _deleteArrival(arrival);
  }

  // ── Suppression via StockService (avec vérification) ────────────────────
  void _deleteArrival(StockArrival arrival) async {
    final variantId = _resolvedVariantId ?? '';
    final pid = widget.productId ?? '';

    // Vérifier si la suppression est possible
    final error = StockService.canDeleteArrival(
      shopId: widget.shopId, productId: pid, variantId: variantId,
      quantity: arrival.quantity, status: arrival.status);
    if (error != null) {
      if (mounted) AppSnack.error(context, error);
      return;
    }

    // 1. Supprimer l'arrivée de Hive EN PREMIER
    HiveBoxes.stockArrivalsBox.delete(arrival.id);

    // 2. Supprimer l'incident lié si bloqué
    if (arrival.hasIssue) {
      final keys = HiveBoxes.incidentsBox.keys.where((k) {
        final m = HiveBoxes.incidentsBox.get(k);
        if (m is! Map) return false;
        return (m['product_id'] == pid && m['quantity'] == arrival.quantity
            && m['created_at'] == arrival.createdAt.toIso8601String());
      }).toList();
      for (final k in keys) HiveBoxes.incidentsBox.delete(k);
    }

    // 3. Recalculer le stock depuis les arrivées restantes
    await StockService.recalculate(
      shopId: widget.shopId, productId: pid, variantId: variantId);

    AppDatabase.notifyProductChange(widget.shopId);
    _load();
    widget.onStockChanged();
  }

  // ── Bottom sheet (création + modification) ──────────────────────────────
  void _showArrivalSheet(BuildContext context, {StockArrival? existing}) {
    final isEdit   = existing != null;
    final qtyCtrl  = TextEditingController(text: '${existing?.quantity ?? 1}');
    final noteCtrl = TextEditingController(text: existing?.note ?? '');
    String status  = existing?.status ?? 'available';
    ArrivalCause cause = existing?.cause ?? ArrivalCause.directRestock;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Center(child: Container(width: 36, height: 4,
                  decoration: BoxDecoration(color: Theme.of(ctx).semantic.borderSubtle,
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 16),
              Row(children: [
                Container(width: 34, height: 34,
                    decoration: BoxDecoration(
                        color: AppColors.secondary.withValues(alpha:0.1),
                        borderRadius: BorderRadius.circular(9)),
                    child: const Icon(Icons.inventory_rounded,
                        size: 17, color: AppColors.secondary)),
                const SizedBox(width: 10),
                Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(isEdit ? 'Modifier l\'arrivée' : 'Enregistrer une arrivée',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(widget.variantName.isEmpty ? 'Variante' : widget.variantName,
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ])),
              ]),
              const SizedBox(height: 20),
              // Quantité
              Align(alignment: Alignment.centerLeft,
                  child: Text('Quantité reçue', style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                  onPressed: () { final v = int.tryParse(qtyCtrl.text) ?? 1;
                    if (v > 1) qtyCtrl.text = '${v - 1}'; },
                  icon: const Icon(Icons.remove_circle_rounded, size: 28),
                  color: AppColors.primary),
                SizedBox(width: 80, child: TextField(
                  controller: qtyCtrl, keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  decoration: InputDecoration(isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    filled: true, fillColor: AppColors.primarySurface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none)),
                )),
                IconButton(
                  onPressed: () { final v = int.tryParse(qtyCtrl.text) ?? 0;
                    qtyCtrl.text = '${v + 1}'; },
                  icon: const Icon(Icons.add_circle_rounded, size: 28),
                  color: AppColors.primary),
              ]),
              const SizedBox(height: 16),
              // Statut
              Align(alignment: Alignment.centerLeft,
                  child: Text('Statut', style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                _StatusChip('Disponible', 'available', status,
                    AppColors.secondary, (v) => setSt(() => status = v)),
                _StatusChip('Endommagé', 'damaged', status,
                    AppColors.warning, (v) => setSt(() => status = v)),
                _StatusChip('Défectueux', 'defective', status,
                    AppColors.error, (v) => setSt(() => status = v)),
                _StatusChip('À inspecter', 'to_inspect', status,
                    AppColors.info, (v) => setSt(() => status = v)),
              ]),
              const SizedBox(height: 16),
              // Cause
              Align(alignment: Alignment.centerLeft,
                  child: Text('Cause', style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
              const SizedBox(height: 8),
              DropdownButtonFormField<ArrivalCause>(
                value: cause,
                decoration: InputDecoration(isDense: true, filled: true,
                  fillColor: AppColors.inputFill,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Theme.of(ctx).semantic.borderSubtle)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Theme.of(ctx).semantic.borderSubtle))),
                items: ArrivalCause.values.map((c) => DropdownMenuItem(
                    value: c, child: Text(c.label,
                        style: const TextStyle(fontSize: 13)))).toList(),
                onChanged: (v) => setSt(() => cause = v ?? cause),
              ),
              const SizedBox(height: 12),
              // Note
              TextField(controller: noteCtrl, style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Note (optionnel)', isDense: true,
                  filled: true, fillColor: AppColors.inputFill,
                  hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Theme.of(ctx).semantic.borderSubtle)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Theme.of(ctx).semantic.borderSubtle)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: AppColors.primary, width: 1.5)))),
              const SizedBox(height: 20),
              SizedBox(width: double.infinity, height: 46,
                child: ElevatedButton.icon(
                  onPressed: () {
                    final qty = int.tryParse(qtyCtrl.text) ?? 0;
                    if (qty <= 0) return;
                    _saveArrival(
                      ctx, existing: existing, qty: qty,
                      status: status, cause: cause,
                      note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                    );
                  },
                  icon: Icon(isEdit ? Icons.check_rounded : Icons.check_circle_rounded, size: 18),
                  label: Text(isEdit ? 'Enregistrer' : 'Confirmer l\'arrivée'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.secondary,
                    foregroundColor: Colors.white, elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Sauvegarde : arrivée OU déclaration d'incident ───────────────────────
  //
  // Nouveau modèle :
  //   • status == 'available' → vraie arrivée fournisseur (physical + avail +qty)
  //   • status != 'available' → incident sur stock existant (avail→blocked,
  //     physical inchangé). Pas de StockArrival créée.
  void _saveArrival(BuildContext ctx, {
    StockArrival? existing, required int qty,
    required String status, required ArrivalCause cause, String? note,
  }) async {
    final now  = DateTime.now();
    final user = LocalStorageService.getCurrentUser();
    final pid = widget.productId ?? '';
    var variantId = _resolvedVariantId;
    if (variantId == null || variantId.isEmpty) {
      final products = AppDatabase.getProductsForShop(widget.shopId);
      final p = products.where((p) => p.id == pid).firstOrNull;
      if (p != null && widget.variantIndex < p.variants.length) {
        variantId = p.variants[widget.variantIndex].id;
      }
    }
    variantId ??= pid;

    final productName = widget.variantName.isEmpty ? 'Produit' : widget.variantName;

    // ─── Si édition : annuler l'ancien d'abord ─────────────────────────────
    if (existing != null) {
      // Annuler l'effet stock de l'ancien enregistrement
      await StockService.editArrival(
        shopId: widget.shopId, productId: pid, variantId: variantId,
        oldQty: existing.quantity, oldStatus: existing.status,
        newQty: 0, newStatus: 'available',
      );
      // Supprimer l'ancienne arrivée
      HiveBoxes.stockArrivalsBox.delete(existing.id);
      // Supprimer l'ancien incident lié (si existant)
      for (final k in HiveBoxes.incidentsBox.keys.toList()) {
        final m = HiveBoxes.incidentsBox.get(k);
        if (m is Map && m['product_id'] == pid
            && m['quantity'] == existing.quantity
            && m['created_at'] == existing.createdAt.toIso8601String()) {
          HiveBoxes.incidentsBox.delete(k); break;
        }
      }
    }

    // ─── Appliquer le nouveau ──────────────────────────────────────────────
    if (status == 'available') {
      // Arrivée fournisseur → créer l'enregistrement + incrémenter available
      final arrival = StockArrival(
        id: existing?.id ?? 'sa_${now.microsecondsSinceEpoch}',
        variantId: variantId, productId: pid,
        shopId: widget.shopId, quantity: qty,
        status: 'available', cause: cause, note: note,
        createdBy: user?.name, createdAt: existing?.createdAt ?? now,
      );
      HiveBoxes.stockArrivalsBox.put(arrival.id, arrival.toMap());
      await StockService.arrivalAvailable(
        shopId: widget.shopId, productId: pid, variantId: variantId,
        quantity: qty, cause: cause.key, notes: note);
    } else {
      // Incident sur stock existant → transfert available → blocked
      final ok = await StockService.blockExisting(
        shopId: widget.shopId, productId: pid, variantId: variantId,
        quantity: qty, status: status, cause: cause.key,
        productName: productName, notes: note);
      if (!ok) {
        if (ctx.mounted) {
          AppSnack.error(ctx, 'Stock disponible insuffisant pour déclarer '
              'cet incident ($qty demandé)');
        }
        return;
      }
    }

    if (ctx.mounted) Navigator.of(ctx).pop();
    _load();
    widget.onStockChanged();
  }
}

// ─── Indicateurs stock 4 champs ──────────────────────────────────────────────

class _StockIndicators extends StatefulWidget {
  final String productId;
  final String shopId;
  final int variantIndex;
  final VoidCallback? onAdjusted;
  const _StockIndicators({required this.productId, required this.shopId,
    required this.variantIndex, this.onAdjusted});

  @override
  State<_StockIndicators> createState() => _StockIndicatorsState();
}

class _StockIndicatorsState extends State<_StockIndicators> {
  /// Id de la location sélectionnée dans le slider.
  /// null = boutique courante (affichée par défaut).
  String? _selectedLocationId;

  Future<void> _openAdjust(BuildContext context, ProductVariant v) async {
    final confirmed = await showAdjustStockSheet(
      context:   context,
      variant:   v,
      shopId:    widget.shopId,
      productId: widget.productId,
    );
    if (confirmed) {
      widget.onAdjusted?.call();
      if (context.mounted) {
        AppSnack.success(context, 'Stock corrigé avec succès');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final products = AppDatabase.getProductsForShop(widget.shopId);
    final p = products.where((p) => p.id == widget.productId).firstOrNull;
    if (p == null || widget.variantIndex >= p.variants.length) {
      return const SizedBox.shrink();
    }
    final v   = p.variants[widget.variantIndex];
    final vid = v.id;

    // Construire la liste des tuiles à afficher :
    //   1. Toujours : la boutique courante (source = variante, live)
    //   2. En plus : toutes les autres locations qui ont un StockLevel pour
    //      cette variante (warehouses / partners alimentés par transferts).
    final shopLoc = AppDatabase.getShopLocation(widget.shopId);
    final userId  = LocalStorageService.getCurrentUser()?.id ?? '';
    final allLocs = AppDatabase.getStockLocationsForOwner(userId);
    final levels  = vid != null
        ? AppDatabase.getStockLevelsForVariant(vid)
        : <dynamic>[];

    final tiles = <_LocationStockTile>[];
    if (shopLoc != null) {
      tiles.add(_LocationStockTile(
        id: shopLoc.id,
        name: shopLoc.name,
        type: shopLoc.type,
        available: v.stockAvailable,
        physical:  v.stockPhysical,
        blocked:   v.stockBlocked,
        ordered:   v.stockOrdered,
        isCurrentShop: true,
      ));
    }
    for (final lvl in levels) {
      if (lvl.locationId == shopLoc?.id) continue; // déjà couverte
      final loc = allLocs.where((l) => l.id == lvl.locationId).firstOrNull;
      if (loc == null) continue;
      tiles.add(_LocationStockTile(
        id: loc.id,
        name: loc.name,
        type: loc.type,
        available: lvl.stockAvailable,
        physical:  lvl.stockPhysical,
        blocked:   lvl.stockBlocked,
        ordered:   lvl.stockOrdered,
        isCurrentShop: false,
      ));
    }

    // Sélection : celle demandée, sinon la boutique courante, sinon la 1re.
    final selectedId = _selectedLocationId ?? shopLoc?.id;
    final selected = tiles.where((t) => t.id == selectedId).firstOrNull
        ?? tiles.firstOrNull;

    // Cas dégradé : aucune location connue (Phase 1 pas encore passée).
    if (selected == null) {
      return _legacyIndicators(context, v);
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Column(children: [
        Row(children: [
          Icon(Icons.inventory_rounded, size: 13, color: AppColors.primary),
          const SizedBox(width: 6),
          Text('Stock détaillé', style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.w700, color: AppColors.primary)),
          const Spacer(),
          // Le bouton "Corriger" n'agit que sur la boutique courante :
          // StockService.adjustment cible la variante, pas le StockLevel.
          if (selected.isCurrentShop)
            InkWell(
              onTap: () => _openAdjust(context, v),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.edit_rounded, size: 12, color: AppColors.primary),
                  const SizedBox(width: 4),
                  Text('Corriger',
                      style: TextStyle(fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary)),
                ]),
              ),
            ),
        ]),
        // Slider d'emplacements (si plus d'un)
        if (tiles.length > 1) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 52,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: tiles.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final t = tiles[i];
                return _LocationChip(
                  data: t,
                  selected: t.id == selected.id,
                  onTap: () => setState(() => _selectedLocationId = t.id),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          _StockCell(
            label: 'Disponible',
            value: selected.available,
            color: AppColors.secondary,
            icon: Icons.check_circle_rounded,
          ),
          _StockCell(
            label: 'Bloqué',
            value: selected.blocked,
            color: selected.blocked > 0
                ? AppColors.error
                : AppColors.textHint,
            icon: Icons.block_rounded,
          ),
          _StockCell(
            label: 'Physique',
            value: selected.physical,
            color: AppColors.info,
            icon: Icons.warehouse_rounded,
          ),
          _StockCell(
            label: 'Commandé',
            value: selected.ordered,
            color: const Color(0xFF8B5CF6),
            icon: Icons.local_shipping_rounded,
          ),
        ]),
      ]),
    );
  }

  /// Fallback quand aucune location n'est connue : affichage de l'ancien
  /// modèle à 4 cellules basé directement sur la variante.
  Widget _legacyIndicators(BuildContext context, ProductVariant v) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Column(children: [
        Row(children: [
          Icon(Icons.inventory_rounded, size: 13, color: AppColors.primary),
          const SizedBox(width: 6),
          Text('Stock détaillé', style: TextStyle(fontSize: 11,
              fontWeight: FontWeight.w700, color: AppColors.primary)),
          const Spacer(),
          InkWell(
            onTap: () => _openAdjust(context, v),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.edit_rounded, size: 12, color: AppColors.primary),
                const SizedBox(width: 4),
                Text('Corriger',
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          _StockCell(label: 'Disponible', value: v.stockAvailable,
              color: AppColors.secondary, icon: Icons.check_circle_rounded),
          _StockCell(label: 'Bloqué', value: v.stockBlocked,
              color: v.stockBlocked > 0
                  ? AppColors.error : AppColors.textHint,
              icon: Icons.block_rounded),
          _StockCell(label: 'Physique', value: v.stockPhysical,
              color: AppColors.info, icon: Icons.warehouse_rounded),
          _StockCell(label: 'Commandé', value: v.stockOrdered,
              color: const Color(0xFF8B5CF6), icon: Icons.local_shipping_rounded),
        ]),
      ]),
    );
  }
}

/// Données aplaties pour une tuile d'emplacement dans le slider.
class _LocationStockTile {
  final String id;
  final String name;
  final StockLocationType type;
  final int available, physical, blocked, ordered;
  /// True si cette tuile correspond à la boutique courante (source = variante).
  final bool isCurrentShop;
  const _LocationStockTile({
    required this.id, required this.name, required this.type,
    required this.available, required this.physical,
    required this.blocked, required this.ordered,
    required this.isCurrentShop,
  });
}

class _LocationChip extends StatelessWidget {
  final _LocationStockTile data;
  final bool selected;
  final VoidCallback onTap;
  const _LocationChip({
    required this.data, required this.selected, required this.onTap,
  });

  Color get _color => switch (data.type) {
    StockLocationType.shop      => AppColors.primary,
    StockLocationType.warehouse => AppColors.info,
    StockLocationType.partner   => AppColors.warning,
  };

  IconData get _icon => switch (data.type) {
    StockLocationType.shop      => Icons.storefront_rounded,
    StockLocationType.warehouse => Icons.warehouse_rounded,
    StockLocationType.partner   => Icons.local_shipping_rounded,
  };

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _color.withValues(alpha:0.12) : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _color : Theme.of(context).semantic.borderSubtle,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_icon, size: 13, color: _color),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(data.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: selected ? _color : Theme.of(context).colorScheme.onSurface)),
              ),
              Text('${data.available} dispo',
                  style: TextStyle(fontSize: 9,
                      color: AppColors.textHint,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ]),
      ),
    );
  }
}

// Le `_AdjustStockDialog` a été déplacé dans
// `widgets/adjust_stock_dialog.dart` pour pouvoir être appelé depuis la
// fiche produit ET depuis le crayon de la liste inventaire (cf.
// `showAdjustStockSheet`). Le bouton "Corriger" du `_StockIndicators`
// ci-dessus utilise cette nouvelle voie.

class _StockCell extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final IconData icon;
  const _StockCell({required this.label, required this.value,
    required this.color, required this.icon});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(height: 3),
      Text('$value', style: TextStyle(fontSize: 14,
          fontWeight: FontWeight.w800, color: color)),
      Text(label, style: TextStyle(fontSize: 9,
          color: AppColors.textHint)),
    ]),
  );
}

class _StatusChip extends StatelessWidget {
  final String label, value, selected;
  final Color color;
  final ValueChanged<String> onTap;
  const _StatusChip(this.label, this.value, this.selected,
      this.color, this.onTap);
  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    return GestureDetector(
      onTap: () => onTap(value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha:0.1) : AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? color : Theme.of(context).semantic.borderSubtle,
              width: active ? 1.5 : 1)),
        child: Text(label, style: TextStyle(fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? color : AppColors.textHint)),
      ),
    );
  }
}

// ─── Section repliable inline ─────────────────────────────────────────────────

class _ExpandSection extends StatefulWidget {
  final IconData     icon;
  final String       label;
  final Widget?      trailing;
  final List<Widget> children;
  final bool         forceOpen;
  const _ExpandSection({
    required this.icon, required this.label,
    this.trailing, required this.children,
    this.forceOpen = false,
  });
  @override State<_ExpandSection> createState() => _ExpandSectionState();
}

class _ExpandSectionState extends State<_ExpandSection> {
  bool _open = false;
  @override
  void didUpdateWidget(_ExpandSection old) {
    super.didUpdateWidget(old);
    if (widget.forceOpen && !_open) setState(() => _open = true);
  }

  @override
  Widget build(BuildContext context) {
    final open = _open || widget.forceOpen;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).semantic.borderSubtle),
      ),
      child: Column(children: [
        GestureDetector(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(children: [
              Icon(widget.icon, size: 14, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.label,
                  style: TextStyle(fontSize: 12,
                      fontWeight: FontWeight.w600, color: AppColors.onSurface))),
              if (widget.trailing != null) widget.trailing!,
              Icon(open
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
                  size: 16, color: AppColors.textHint),
            ]),
          ),
        ),
        if (open && widget.children.isNotEmpty) ...[
          const Divider(height: 1, color: Color(0xFFEEEEEE)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: widget.children),
          ),
        ],
      ]),
    );
  }
}

// ─── Images secondaires ───────────────────────────────────────────────────────

class _SecondaryImagesRow extends StatelessWidget {
  final List<Uint8List> bytesList; // nouvelles images choisies (session en cours)
  final List<String>    urls;      // images sauvegardées (chemins locaux ou http)
  final VoidCallback    onAdd;
  final void Function(int index, bool isUrl) onRemoveItem;
  const _SecondaryImagesRow({
    required this.bytesList, required this.urls,
    required this.onAdd, required this.onRemoveItem,
  });

  Widget _buildImg(Widget img, VoidCallback onRemove) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: _SecImg(child: img, onRemove: onRemove),
  );

  @override
  Widget build(BuildContext context) {
    final brokenIcon = Icon(Icons.broken_image, color: AppColors.textHint);
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          // Images sauvegardées (URLs)
          ...List.generate(urls.length, (i) {
            final url = urls[i];
            final Widget img = url.startsWith('http')
                ? Image.network(url, fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                    errorBuilder: (_, __, ___) => brokenIcon)
                : (kIsWeb
                    ? brokenIcon
                    : Image.file(File(url), fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                        errorBuilder: (_, __, ___) => brokenIcon));
            return _buildImg(img, () => onRemoveItem(i, true));
          }),
          // Nouvelles images choisies (bytes en mémoire)
          ...List.generate(bytesList.length, (i) => _buildImg(
            Image.memory(bytesList[i], fit: BoxFit.cover,
                filterQuality: FilterQuality.high),
                () => onRemoveItem(i, false),
          )),
          // Bouton ajouter
          GestureDetector(
            onTap: onAdd,
            child: Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                color: AppColors.primarySurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.primary.withValues(alpha:0.3)),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_rounded, size: 16, color: AppColors.primary),
                const SizedBox(height: 2),
                Text(context.l10n.prodChooseFile,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 7, color: AppColors.primary)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SecImg extends StatelessWidget {
  final Widget child;
  final VoidCallback onRemove;
  const _SecImg({required this.child, required this.onRemove});
  @override
  Widget build(BuildContext context) => Stack(clipBehavior: Clip.none, children: [
    ClipRRect(borderRadius: BorderRadius.circular(8),
        child: SizedBox(width: 52, height: 52, child: child)),
    Positioned(top: -4, right: -4,
        child: GestureDetector(
          onTap: onRemove,
          child: Container(
            width: 18, height: 18,
            decoration: const BoxDecoration(
                color: AppColors.error, shape: BoxShape.circle),
            child: const Icon(Icons.close_rounded,
                size: 11, color: Colors.white),
          ),
        )),
  ]);
}

// ─── Row dépense ──────────────────────────────────────────────────────────────

class _ExpRow extends StatelessWidget {
  final _Expense expense;
  final int index;
  final VoidCallback onRemove, onChanged;
  const _ExpRow({required this.expense, required this.index,
    required this.onRemove, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Expanded(flex: 3, child: _TF(expense.description,
            l.prodExpenseHint, Icons.receipt_outlined,
            onChanged: (_) => onChanged(),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Requis' : null)),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: _TF(expense.amount, '0',
            Icons.attach_money_rounded,
            keyboardType: TextInputType.number,
            onChanged: (_) => onChanged(),
            validator: (v) => (v ?? '').trim().isEmpty ? 'Requis' : null)),
        IconButton(onPressed: onRemove,
            icon: Icon(Icons.close_rounded, size: 16,
                color: AppColors.textHint),
            padding: const EdgeInsets.only(left: 4),
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28)),
      ]),
    );
  }
}

// ─── Barre d'étapes ───────────────────────────────────────────────────────────

class _StepBar extends StatelessWidget {
  final int current, total;
  final List<String> titles;
  final List<IconData> icons;
  final ValueChanged<int> onTap;
  const _StepBar({required this.current, required this.total,
    required this.titles, required this.icons, required this.onTap});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(color: Theme.of(context).semantic.borderSubtle))),
    child: Row(children: List.generate(total, (i) {
      final done   = i < current;
      final active = i == current;
      final col    = active ? AppColors.primary
          : done ? AppColors.secondary : AppColors.textHint;
      return Expanded(child: GestureDetector(
        onTap: () => onTap(i),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            if (i > 0) Expanded(child: Container(height: 2,
                color: done ? AppColors.secondary : Theme.of(context).semantic.borderSubtle)),
            Container(
              width: 26, height: 26,
              decoration: BoxDecoration(
                color: active ? AppColors.primary
                    : done ? AppColors.secondary.withValues(alpha:0.12)
                    : AppColors.inputFill,
                shape: BoxShape.circle,
                border: Border.all(color: col, width: 1.5),
              ),
              child: Icon(done ? Icons.check_rounded : icons[i],
                  size: 13,
                  color: active ? Colors.white
                      : done ? AppColors.secondary : AppColors.textHint),
            ),
            if (i < total - 1) Expanded(child: Container(height: 2,
                color: done ? AppColors.secondary : Theme.of(context).semantic.borderSubtle)),
          ]),
          const SizedBox(height: 3),
          Text(titles[i], maxLines: 1, overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 9,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                  color: active ? AppColors.primary
                      : done ? AppColors.secondary : AppColors.textHint)),
        ]),
      ));
    })),
  );
}

// ─── Navigation bas ───────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  final int step, total;
  final VoidCallback onPrev, onNext, onSubmit;
  final bool isSaving;
  const _BottomNav({required this.step, required this.total,
    required this.onPrev, required this.onNext, required this.onSubmit,
    this.isSaving = false});

  @override
  Widget build(BuildContext context) {
    final l      = context.l10n;
    final isLast = step == total - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: Theme.of(context).semantic.borderSubtle))),
      child: Row(children: [
        if (step > 0)
          OutlinedButton.icon(
            onPressed: isSaving ? null : onPrev,
            icon: const Icon(Icons.arrow_back_ios_rounded, size: 13),
            label: Text(l.prodPrev),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.onSurface,
              side: BorderSide(color: Theme.of(context).semantic.borderSubtle),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              minimumSize: Size.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          )
        else
          const SizedBox.shrink(),
        const Spacer(),
        ElevatedButton(
          onPressed: (isLast && isSaving) ? null : (isLast ? onSubmit : onNext),
          style: ElevatedButton.styleFrom(
            backgroundColor: isLast ? AppColors.secondary : AppColors.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            minimumSize: Size.zero,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: isSaving && isLast
              ? const SizedBox(
              width: 16, height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
              : Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isLast ? Icons.check_rounded
                : Icons.arrow_forward_ios_rounded, size: 13),
            const SizedBox(width: 6),
            Text(isLast ? l.inventaireSave : l.prodNext),
          ]),
        ),
      ]),
    );
  }
}

// ─── Helpers de rendu d'images ────────────────────────────────────────────────

/// Affiche une image de variante en gérant les 3 cas (priorité décroissante) :
///  - `bytes` en mémoire (image fraîchement choisie, compatible web)
///  - `url` http(s) (image distante uploadée vers Supabase)
///  - `url` chemin local (sur mobile uniquement, web tombe sur placeholder)
Widget _buildVariantImage({
  required BuildContext context,
  required Uint8List? bytes,
  required String?    url,
  required Widget     placeholder,
  double              displaySize = 80,
  BoxFit              fit = BoxFit.cover,
}) {
  // Anti-grain : on charge l'image à une taille proche de la vignette au lieu
  // de l'image brute ~2048 px. Décoder/afficher à fort ratio en une passe
  // produit de l'aliasing sur web même en FilterQuality.high. Réseau →
  // vignette redimensionnée côté serveur (StorageService.thumbUrl) ;
  // mémoire/fichier → `cacheWidth`.
  // Largeur cible DPR-AWARE : taille logique de la vignette × densité écran,
  // bornée [120, 600]. Sur un écran rétina (DPR 2-3) une vignette 80 px a
  // besoin de 160-240 px réels — une valeur fixe basse pixeliserait.
  const fq = FilterQuality.high;
  final dpr = MediaQuery.of(context).devicePixelRatio;
  final int thumbPx = (displaySize * dpr).clamp(120.0, 600.0).round();
  if (bytes != null) {
    return Image.memory(bytes, fit: fit, filterQuality: fq,
        // cacheWidth omis sur web (décodage canvas peu fiable avec) ; l'aperçu
        // mémoire est de toute façon transitoire (avant upload → bascule URL).
        cacheWidth: kIsWeb ? null : thumbPx,
        errorBuilder: (_, __, ___) => placeholder);
  }
  if (url != null && url.isNotEmpty) {
    if (url.startsWith('http')) {
      return Image.network(StorageService.thumbUrl(url, width: thumbPx),
          fit: fit, filterQuality: fq,
          // Repli sur l'image brute si la vignette transformée échoue.
          errorBuilder: (_, __, ___) => Image.network(url,
              fit: fit, filterQuality: fq,
              errorBuilder: (_, __, ___) => placeholder));
    }
    if (!kIsWeb) {
      return Image.file(File(url), fit: fit, filterQuality: fq,
          cacheWidth: thumbPx,
          errorBuilder: (_, __, ___) => placeholder);
    }
  }
  return placeholder;
}

// ─── Image placeholder ────────────────────────────────────────────────────────

class _ImgPlaceholderSmall extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    color: AppColors.inputFill,
    child: Icon(Icons.image_outlined, color: AppColors.textHint),
  );
}

// ─── Widgets atomiques ────────────────────────────────────────────────────────

class _StepScroll extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final List<Widget> children;
  const _StepScroll({required this.formKey, required this.children});
  @override
  Widget build(BuildContext context) {
    // AppScaffold utilise resizeToAvoidBottomInset:false → le clavier ne
    // rétrécit PAS le body. On ajoute donc sa hauteur en marge basse pour que
    // les derniers champs puissent défiler AU-DESSUS du clavier.
    final keyboard = MediaQuery.of(context).viewInsets.bottom;
    return Form(
      key: formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: ListView(
        padding: EdgeInsets.fromLTRB(16, 14, 16, 8 + keyboard),
        children: children,
      ),
    );
  }
}

Widget _gap({double h = 12}) => SizedBox(height: h);


class _LF extends StatelessWidget {
  final String label;
  final bool req;
  final Widget child;
  const _LF(this.label, {required this.child, this.req = false});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (label.isNotEmpty) ...[
        RichText(text: TextSpan(
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
              color: AppColors.textSecondary),
          children: [
            TextSpan(text: label),
            if (req) const TextSpan(text: ' *',
                style: TextStyle(color: AppColors.error,
                    fontWeight: FontWeight.w700)),
          ],
        )),
        const SizedBox(height: 4),
      ],
      child,
    ],
  );
}

class _Row2 extends StatelessWidget {
  final List<Widget> c;
  const _Row2(this.c);
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (_, cs) => cs.maxWidth < 340
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [c[0], const SizedBox(height: 10), c[1]])
        : Row(children: [
      Expanded(child: c[0]),
      const SizedBox(width: 10),
      Expanded(child: c[1]),
    ]),
  );
}

class _ToggleRow extends StatelessWidget {
  final String label, sub;
  final bool value;
  final Color color;
  final ValueChanged<bool> onChange;
  const _ToggleRow(this.label, this.sub, this.value, this.color, this.onChange);
  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 13,
          fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
      Text(sub, style: TextStyle(fontSize: 11, color: AppColors.textHint)),
    ])),
    AppSwitch(value: value, onChanged: onChange),
  ]);
}

class _Stars extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChange;
  const _Stars(this.value, this.onChange);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => GestureDetector(
        onTap: () => onChange(i + 1),
        child: Padding(padding: const EdgeInsets.only(right: 2),
            child: Icon(i < value
                ? Icons.star_rounded : Icons.star_outline_rounded,
                size: 26, color: AppColors.warning)),
      )));
}

class _DateBtn extends StatelessWidget {
  final DateTime? date;
  final String hint;
  final ValueChanged<DateTime> onPick;
  const _DateBtn({required this.date, required this.hint, required this.onPick});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () async {
      final d = await showDatePicker(context: context,
          initialDate: date ?? DateTime.now(),
          firstDate: DateTime(2020), lastDate: DateTime(2040));
      if (d != null) onPick(d);
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).semantic.borderSubtle)),
      child: Row(children: [
        Icon(Icons.calendar_today_rounded, size: 14, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(child: Text(
          date == null ? hint
              : '${date!.day.toString().padLeft(2,'0')}/'
              '${date!.month.toString().padLeft(2,'0')}/${date!.year}',
          style: TextStyle(fontSize: 12,
              color: date == null
                  ? const Color(0xFFBBBBBB)
                  : Theme.of(context).colorScheme.onSurface),
        )),
      ]),
    ),
  );
}

class _AddBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _AddBtn(this.label, this.onTap);
  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onTap,
    icon: const Icon(Icons.add_rounded, size: 16),
    label: Text(label, style: const TextStyle(fontSize: 12)),
    style: TextButton.styleFrom(foregroundColor: AppColors.primary,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero),
  );
}

class _InfoBanner extends StatelessWidget {
  final String text;
  const _InfoBanner(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(color: AppColors.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBAE6FD))),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.info_outline, size: 14, color: AppColors.primary),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontSize: 11,
          color: AppColors.onSurface, height: 1.4))),
    ]),
  );
}

/// Pendant de [_InfoBanner] en teinte d'alerte — même gabarit, mêmes tailles.
/// Pour les manques non bloquants (marque/catégorie absentes en modification).
class _WarnBanner extends StatelessWidget {
  final String text;
  const _WarnBanner(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppColors.warning.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.warning.withValues(alpha: 0.45)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.warning_amber_rounded, size: 14,
          color: AppColors.warning),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontSize: 11,
          color: AppColors.onSurface, height: 1.4))),
    ]),
  );
}

/// Complétude de la fiche, sous la barre d'étapes. Dit à l'utilisateur ce
/// qu'il lui reste à renseigner sans le bloquer.
class _ProfileProgressBar extends StatelessWidget {
  final double value;
  const _ProfileProgressBar({required this.value});

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).round();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(bottom: BorderSide(
            color: Theme.of(context).semantic.borderSubtle)),
      ),
      child: Row(children: [
        Text('Profil produit', style: AppTextStyles.caption),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 4,
              backgroundColor: AppColors.inputFill,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('$pct %', style: AppTextStyles.caption.copyWith(
            color: AppColors.primary, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

/// État du contrôle de SKU, rendu dans le champ lui-même.
class _SkuStatusDot extends StatelessWidget {
  final _SkuStatus status;
  const _SkuStatusDot({required this.status});

  @override
  Widget build(BuildContext context) => switch (status) {
    _SkuStatus.empty     => const SizedBox.shrink(),
    _SkuStatus.checking  => const Padding(
        padding: EdgeInsets.only(right: 10),
        child: SizedBox(width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6))),
    _SkuStatus.available => const Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.check_circle_rounded,
            size: 18, color: AppColors.secondary)),
    _SkuStatus.taken     => const Padding(
        padding: EdgeInsets.only(right: 8),
        child: Icon(Icons.error_rounded, size: 18, color: AppColors.error)),
  };
}

class _BenefitBanner extends StatelessWidget {
  final double effectiveCost, benefit, margin, expensePerUnit;
  final AppLocalizations l;
  const _BenefitBanner({required this.effectiveCost, required this.benefit,
    required this.margin, required this.expensePerUnit, required this.l});

  @override
  Widget build(BuildContext context) {
    final pos          = benefit > 0;
    final benefitColor = pos ? AppColors.secondary : AppColors.error;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: pos ? AppColors.secondary.withValues(alpha: 0.12) : AppColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: pos ? const Color(0xFF6EE7B7) : const Color(0xFFFCA5A5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.prodEffectiveCost,
                    style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                Text(CurrencyFormatter.format(effectiveCost),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: AppColors.onSurface)),
              ])),
          Container(width: 1, height: 32,
              color: pos ? const Color(0xFF6EE7B7) : const Color(0xFFFCA5A5)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.prodBenefit,
                    style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                Text(CurrencyFormatter.format(benefit),
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: benefitColor)),
              ])),
          Container(width: 1, height: 32,
              color: pos ? const Color(0xFF6EE7B7) : const Color(0xFFFCA5A5)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.prodMarginPOS,
                    style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                Text('${margin.toStringAsFixed(1)}%',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: benefitColor)),
              ])),
        ]),
        if (expensePerUnit > 0) ...[
          const SizedBox(height: 6),
          Text(
              '${l.prodExpensePerUnit}: +${CurrencyFormatter.format(expensePerUnit.ceilToDouble())}/u inclus dans le prix de revient',
              style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
        ],
      ]),
    );
  }
}

class _CalcBanner extends StatelessWidget {
  final String label, value, sub;
  final bool? positive;
  const _CalcBanner({required this.label, required this.value,
    required this.sub, this.positive});
  @override
  Widget build(BuildContext context) {
    final c = positive == null ? AppColors.primary
        : positive! ? AppColors.secondary : AppColors.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: c.withValues(alpha:0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: c.withValues(alpha:0.25))),
      child: Row(children: [
        Icon(Icons.auto_fix_high_rounded, size: 13, color: c),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 10, color: c,
                  fontWeight: FontWeight.w600)),
              Text(sub, style: TextStyle(fontSize: 10,
                  color: AppColors.textSecondary)),
            ])),
        Text(value, style: TextStyle(fontSize: 12,
            fontWeight: FontWeight.w800, color: c)),
      ]),
    );
  }
}

class _TF extends StatefulWidget {
  final TextEditingController ctrl;
  final String hint;
  final IconData icon;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  /// Élément affiché à droite dans le champ (état du SKU, par exemple).
  final Widget? suffix;
  const _TF(this.ctrl, this.hint, this.icon, {this.maxLines = 1,
    this.keyboardType, this.validator, this.onChanged, this.autofocus = false,
    this.suffix});

  @override
  State<_TF> createState() => _TFState();
}

class _TFState extends State<_TF> {
  late final FocusNode _node;

  @override
  void initState() {
    super.initState();
    _node = FocusNode();
    _node.addListener(_ensureVisibleOnFocus);
  }

  // Auto-scroll : dès qu'un champ prend le focus (tap OU navigation clavier),
  // on le fait défiler dans la zone visible — jamais caché hors écran ni
  // derrière le clavier mobile. alignment 0.15 = champ placé vers le haut du
  // viewport restant (au-dessus du clavier).
  void _ensureVisibleOnFocus() {
    if (!_node.hasFocus || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || Scrollable.maybeOf(context) == null) return;
      final keyboardOpen = MediaQuery.of(context).viewInsets.bottom > 0;
      if (keyboardOpen) {
        // Clavier ouvert (mobile) : place le champ vers le haut du viewport,
        // garanti au-dessus du clavier.
        Scrollable.ensureVisible(context,
            alignment: 0.15,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic);
      } else {
        // Desktop / sans clavier : défilement MINIMAL, uniquement si le champ
        // déborde de la zone visible — évite tout saut intempestif.
        context.findRenderObject()?.showOnScreen(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic);
      }
    });
  }

  @override
  void dispose() {
    _node.removeListener(_ensureVisibleOnFocus);
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Pas de navigation auto vers le champ suivant : Entrée (desktop) ne
    // déplace PLUS le focus ; sur mobile la touche vaut « OK » (ferme le
    // clavier). Seul le 1er champ (Nom) reçoit un autofocus à l'ouverture.
    // Multi-lignes → saut de ligne. (L'auto-scroll de confort au focus reste.)
    final action = widget.maxLines > 1
        ? TextInputAction.newline : TextInputAction.done;
    return TextFormField(
      controller: widget.ctrl, maxLines: widget.maxLines,
      focusNode: _node,
      autofocus: widget.autofocus,
      textInputAction: action,
      keyboardType: widget.keyboardType, onChanged: widget.onChanged,
      validator: widget.validator,
      style: const TextStyle(fontSize: 13, color: Color(0xFF1A1D2E)),
      inputFormatters: widget.keyboardType == TextInputType.number
          ? [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))] : null,
      decoration: InputDecoration(
        hintText: widget.hint,
        hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
        prefixIcon: Icon(widget.icon, size: 15, color: const Color(0xFFAAAAAA)),
        suffixIcon: widget.suffix,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 34, minHeight: 34),
        filled: true, fillColor: AppColors.inputFill, isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
        errorBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.error)),
      ),
    );
  }
}

// ─── Sélecteur de fournisseur ──────────────────────────────────────────────
// Champ texte avec icône loupe ouvrant une sheet avec la liste des fournisseurs
// de la boutique. Au choix, remplit le nom et déclenche [onPicked]. La saisie
// libre reste possible (pour créer un fournisseur hors liste).
class _SupplierPickField extends StatelessWidget {
  final TextEditingController controller;
  final List<Supplier> suppliers;
  final Supplier? selected;
  final ValueChanged<Supplier> onPicked;
  final VoidCallback onCleared;
  final ValueChanged<String> onManualChange;

  const _SupplierPickField({
    required this.controller,
    required this.suppliers,
    required this.selected,
    required this.onPicked,
    required this.onCleared,
    required this.onManualChange,
  });

  Future<void> _openPicker(BuildContext context) async {
    if (suppliers.isEmpty) {
      AppSnack.info(context,
          'Aucun fournisseur enregistré. Ajoutez-en depuis Inventaire → Fournisseurs.');
      return;
    }
    final picked = await showModalBottomSheet<Supplier>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _SupplierPickerSheet(suppliers: suppliers),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = selected != null;
    return TextFormField(
      controller: controller,
      onChanged: onManualChange,
      style: const TextStyle(fontSize: 13, color: Color(0xFF1A1D2E)),
      decoration: InputDecoration(
        hintText: 'Ex: Distributeur ABC',
        hintStyle: const TextStyle(color: Color(0xFFBBBBBB), fontSize: 12),
        prefixIcon: const Icon(Icons.business_rounded,
            size: 15, color: Color(0xFFAAAAAA)),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasSelection)
              IconButton(
                icon: Icon(Icons.close_rounded,
                    size: 16, color: AppColors.textHint),
                tooltip: 'Effacer le fournisseur',
                onPressed: onCleared,
              ),
            IconButton(
              icon: Icon(Icons.search_rounded,
                  size: 18, color: AppColors.primary),
              tooltip: 'Choisir un fournisseur existant',
              onPressed: () => _openPicker(context),
            ),
          ],
        ),
        filled: true, fillColor: AppColors.inputFill, isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
      ),
    );
  }
}

// ─── Sheet de sélection de fournisseur ─────────────────────────────────────
class _SupplierPickerSheet extends StatefulWidget {
  final List<Supplier> suppliers;
  const _SupplierPickerSheet({required this.suppliers});

  @override
  State<_SupplierPickerSheet> createState() => _SupplierPickerSheetState();
}

class _SupplierPickerSheetState extends State<_SupplierPickerSheet> {
  String _query = '';

  List<Supplier> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.suppliers;
    return widget.suppliers.where((s) =>
      s.name.toLowerCase().contains(q) ||
      (s.phone ?? '').toLowerCase().contains(q) ||
      (s.email ?? '').toLowerCase().contains(q)
    ).toList();
  }

  @override
  Widget build(BuildContext context) {
    final items = _filtered;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.75),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Poignée
              Center(child: Container(width: 36, height: 4,
                  decoration: BoxDecoration(
                      color: Theme.of(context).semantic.borderSubtle,
                      borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 12),
              Text('Choisir un fournisseur',
                  style: TextStyle(fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Rechercher par nom, téléphone, email…',
                  hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFBBBBBB)),
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: AppColors.textHint),
                  filled: true, fillColor: AppColors.inputFill,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 11),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Theme.of(context).semantic.borderSubtle)),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: items.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: Text('Aucun fournisseur trouvé',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textHint)),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: items.length,
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: Theme.of(context).semantic.borderSubtle),
                        itemBuilder: (_, i) {
                          final s = items[i];
                          return InkWell(
                            onTap: () => Navigator.of(context).pop(s),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 10),
                              child: Row(children: [
                                Container(
                                  width: 34, height: 34,
                                  decoration: BoxDecoration(
                                    color: AppColors.primary.withValues(alpha:0.10),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(Icons.local_shipping_rounded,
                                      size: 16, color: AppColors.primary),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(s.name,
                                          style: TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w600,
                                              color: Theme.of(context).colorScheme.onSurface)),
                                      if ((s.phone ?? '').isNotEmpty ||
                                          (s.email ?? '').isNotEmpty)
                                        Text(
                                            [s.phone, s.email]
                                                .where((e) =>
                                                    e != null && e.isNotEmpty)
                                                .join(' · '),
                                            style: TextStyle(
                                                fontSize: 11,
                                                color: AppColors.textHint)),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right_rounded,
                                    size: 18, color: Color(0xFFBBBBBB)),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Carte infos fournisseur sélectionné ───────────────────────────────────
class _SupplierInfoCard extends StatelessWidget {
  final Supplier supplier;
  const _SupplierInfoCard({required this.supplier});

  @override
  Widget build(BuildContext context) {
    final rows = <_SupplierInfoRow>[];
    if ((supplier.phone ?? '').isNotEmpty) {
      rows.add(_SupplierInfoRow(
          icon: Icons.phone_outlined, label: 'Téléphone',
          value: supplier.phone!));
    }
    if ((supplier.email ?? '').isNotEmpty) {
      rows.add(_SupplierInfoRow(
          icon: Icons.email_outlined, label: 'Email',
          value: supplier.email!));
    }
    if ((supplier.address ?? '').isNotEmpty) {
      rows.add(_SupplierInfoRow(
          icon: Icons.location_on_outlined, label: 'Adresse',
          value: supplier.address!));
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha:0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.primary.withValues(alpha:0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.check_circle_rounded,
                size: 14, color: AppColors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Fournisseur enregistré — infos remplies',
                  style: TextStyle(fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary)),
            ),
          ]),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...rows.map((r) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: r,
                )),
          ] else ...[
            const SizedBox(height: 4),
            Text(
                'Aucun contact renseigné pour ce fournisseur.',
                style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          ],
        ],
      ),
    );
  }
}

class _SupplierInfoRow extends StatelessWidget {
  final IconData icon;
  final String label, value;
  const _SupplierInfoRow({required this.icon,
      required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 13, color: AppColors.textSecondary),
      const SizedBox(width: 6),
      SizedBox(
        width: 72,
        child: Text(label,
            style: TextStyle(fontSize: 11, color: AppColors.textHint)),
      ),
      Expanded(
        child: Text(value,
            style: TextStyle(fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface)),
      ),
    ],
  );
}