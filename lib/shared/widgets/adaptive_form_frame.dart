import 'package:flutter/material.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/theme/app_theme.dart';
import 'form_sheet.dart';

/// Largeur en dessous de laquelle un formulaire s'ouvre en **page pleine**
/// (Navigator.push) plutôt qu'en bottom sheet. 600 dp = breakpoint Material
/// standard mobile/tablet.
const double kFormMobileBreakpoint = 600;

/// True si on est sur un écran considéré comme "mobile" (<600 dp).
bool isMobileFormScreen(BuildContext context) =>
    MediaQuery.of(context).size.width < kFormMobileBreakpoint;

/// Ouvre un formulaire en mode adaptatif selon la taille d'écran :
///
///   • Mobile (<600 dp) → `Navigator.push(MaterialPageRoute)` : vraie page
///     avec AppBar + flèche back native (gère gesture iOS / système Android,
///     clavier via `Scaffold.resizeToAvoidBottomInset`).
///   • Desktop / web large → `showFormSheet` (bottom sheet verrouillé).
///
/// Le `builder` doit retourner un [AdaptiveFormFrame] qui rend le bon
/// châssis (Scaffold ou Column+FormSheetHeader) automatiquement.
Future<T?> showAdaptiveFormSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  if (isMobileFormScreen(context)) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute<T>(builder: builder),
    );
  }
  return showFormSheet<T>(context: context, builder: builder);
}

/// Châssis de formulaire qui s'adapte automatiquement au mode :
///
///   • Mobile : `Scaffold(appBar: AppBar(BackButton, title), body: …)`.
///     Le clavier est géré nativement (Scaffold.resizeToAvoidBottomInset).
///     `actions` apparaissent à droite de l'AppBar.
///   • Desktop : `Column(FormSheetHeader, Divider, body)` dans un sheet
///     bordé. Le `body` est wrappé dans un `SingleChildScrollView` pour
///     éviter qu'un long contenu déborde quand le clavier s'affiche.
///
/// Usage :
/// ```dart
/// showAdaptiveFormSheet(
///   context: context,
///   builder: (_) => AdaptiveFormFrame(
///     title: 'Nouveau client',
///     icon: Icons.person_outline_rounded,
///     body: _buildContent(),
///   ),
/// );
/// ```
class AdaptiveFormFrame extends StatelessWidget {
  final String   title;
  final String?  subtitle;
  final IconData? icon;
  final Color?   iconColor;
  /// Corps du formulaire (champs + bouton "Enregistrer" en général).
  /// Ne PAS inclure de header — le widget se charge de l'AppBar (mobile)
  /// ou du FormSheetHeader (desktop).
  final Widget   body;
  /// Actions affichées à droite (AppBar.actions sur mobile,
  /// FormSheetHeader.trailing sur desktop). Typiquement un bouton compact
  /// "Enregistrer" en haut.
  final List<Widget>? actions;

  /// Barre d'actions ÉPINGLÉE en bas (hors du scroll) — toujours visible
  /// au-dessus du clavier. À utiliser pour les boutons Annuler/Valider des
  /// formulaires au contenu long : sinon, placés en fin de `body`, ils
  /// défilent sous la ligne de flottaison et disparaissent derrière le
  /// clavier (l'utilisateur croit qu'« aucun bouton n'apparaît »).
  final Widget? footer;

  const AdaptiveFormFrame({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    required this.body,
    this.actions,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final theme  = Theme.of(context);
    final scheme = theme.colorScheme;

    if (isMobileFormScreen(context)) {
      // Mode page mobile : Scaffold gère le clavier nativement.
      // Wrappe le body dans un SingleChildScrollView pour les contenus
      // qui dépassent la hauteur d'écran (form long, multi-lignes, etc.).
      // Si la page interne a déjà son propre scroll, ce SingleChildScrollView
      // imbriqué reste safe (le scroll interne prend précédence).
      return Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: scheme.surface,
          surfaceTintColor: scheme.surface,
          elevation: 0.5,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded,
                color: scheme.onSurface),
            // `maybePop` et non `pop` : un formulaire qui a quelque chose à
            // demander avant de fermer (un `PopScope`) doit pouvoir le faire
            // ICI aussi. `pop` force la fermeture et court-circuite la
            // question ; sur mobile, cette flèche EST le geste de sortie.
            // Sans `PopScope` au-dessus, les deux sont équivalents — aucun
            // formulaire existant ne change de comportement.
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: AppTextStyles.label.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface)),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!,
                    style: AppTextStyles.caption.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.6))),
            ],
          ),
          actions: actions,
        ),
        // Sans footer : comportement historique (boutons en fin de body,
        // qui défilent). Avec footer : le body défile dans l'espace restant
        // et la barre d'actions est épinglée en bas (le Scaffold se
        // redimensionne au-dessus du clavier → footer toujours visible).
        body: footer == null
            ? SingleChildScrollView(
                // Permet au scroll de "rebondir" jusqu'au-dessus du clavier.
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).viewInsets.bottom),
                child: body,
              )
            : Column(
                children: [
                  Expanded(child: SingleChildScrollView(child: body)),
                  Material(
                    color: scheme.surface,
                    elevation: 8,
                    child: SafeArea(top: false, child: footer!),
                  ),
                ],
              ),
      );
    }
    // Mode sheet desktop : verrouillé, bouton X intégré au header.
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.92,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FormSheetHeader(
                title: title,
                subtitle: subtitle,
                icon: icon,
                iconColor: iconColor,
                trailing: actions,
              ),
              Divider(height: 1, color: theme.semantic.borderSubtle),
              Flexible(
                child: SingleChildScrollView(child: body),
              ),
              // Barre d'actions épinglée sous le scroll, séparée par une
              // bordure pour bien la distinguer du contenu (cf. footer mobile).
              if (footer != null)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    border: Border(
                        top: BorderSide(color: theme.semantic.borderSubtle)),
                  ),
                  child: footer!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
