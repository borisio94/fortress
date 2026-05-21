import 'dart:typed_data';

import 'package:flutter/painting.dart' show Color;
import 'package:pdf/pdf.dart';

import '../../../core/services/logo_color_extractor.dart';

/// Palette + assets utilisés pour générer une facture PDF
/// personnalisée. Le service `InvoiceService.generatePdf` ne consomme
/// QUE ce thème — aucune couleur n'est codée en dur dans les widgets
/// `pw.*`. Ça permet de changer l'identité visuelle d'une boutique
/// sans toucher au layout.
class InvoiceTheme {
  /// Couleur principale (titres, en-tête tableau, total TTC, lignes).
  /// Dérivée du logo via `LogoColorExtractor`, ou fallback `#1A1A1A`.
  final PdfColor primary;
  /// Couleur secondaire (libellés discrets, remise, reste dû).
  /// Fallback `#555555`.
  final PdfColor secondary;
  /// Bytes du logo à embarquer dans l'en-tête. `null` → en-tête texte
  /// seul (le pipeline reste lisible sans logo).
  final Uint8List? logoBytes;

  // ── Couleurs neutres (constantes design, jamais dérivées du logo) ─
  /// Fond de page facture — un blanc cassé doux qui se distingue d'un
  /// vrai blanc imprimante. Constant cross-boutique.
  static const PdfColor pageBackground   = PdfColor.fromInt(0xFFFAFAF8);
  /// Alternance lignes table — léger contraste vs `pageBackground`.
  static const PdfColor rowAltBackground = PdfColor.fromInt(0xFFF3F3F0);
  /// Texte principal — noir doux pour ne pas écraser le rendu papier.
  static const PdfColor textPrimary      = PdfColor.fromInt(0xFF1A1A1A);
  /// Texte secondaire — gris ardoise lisible sur fond clair.
  static const PdfColor textSecondary    = PdfColor.fromInt(0xFF555555);
  /// Lignes très discrètes (entre totaux, pied de page).
  static const PdfColor divider          = PdfColor.fromInt(0xFFCCCCCC);
  /// Texte pied de page sous le « merci » — gris très clair, presque
  /// invisible mais lisible de près.
  static const PdfColor footerSubtle     = PdfColor.fromInt(0xFF888888);
  /// Mention « Fortress POS » — le plus discret possible.
  static const PdfColor footerBrand      = PdfColor.fromInt(0xFFBBBBBB);
  static const PdfColor white            = PdfColors.white;

  const InvoiceTheme({
    required this.primary,
    required this.secondary,
    this.logoBytes,
  });

  /// Construit le thème depuis le cache local (couleurs déjà extraites
  /// + bytes du logo si dispo). Aucune I/O. Le caller a la charge de
  /// remplir le cache via `LogoStorageService.fetchBytes` +
  /// `LogoColorExtractor.extractAndCache` (typiquement au moment de
  /// l'upload du logo).
  factory InvoiceTheme.fromCache({
    required String shopId,
    Uint8List? logoBytes,
  }) {
    final colors = LogoColorExtractor.cached(shopId);
    return InvoiceTheme(
      primary:   _toPdf(colors.primary),
      secondary: _toPdf(colors.secondary),
      logoBytes: logoBytes,
    );
  }

  /// Fallback explicite sans logo — utilisé quand `shopId` n'est pas
  /// connu (test, debug) ou quand le cache n'a pas encore été rempli.
  static const InvoiceTheme fallback = InvoiceTheme(
    primary:   textPrimary,
    secondary: textSecondary,
    logoBytes: null,
  );

  static PdfColor _toPdf(Color c) {
    final a = (c.a * 255).round() & 0xff;
    final r = (c.r * 255).round() & 0xff;
    final g = (c.g * 255).round() & 0xff;
    final b = (c.b * 255).round() & 0xff;
    return PdfColor.fromInt((a << 24) | (r << 16) | (g << 8) | b);
  }
}
